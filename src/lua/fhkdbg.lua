local cli = require "cli"
local conf = require "conf"
local fhk = require "fhk"
local typing = require "typing"
local aux = require "aux"
local ffi = require "ffi"
local C = ffi.C

local function hook_udata(fvars, fmodels)
	for name,fv in pairs(fvars) do
		fv.udata = ffi.cast("char *", name)
	end

	for name,fm in pairs(fmodels) do
		fm.udata = ffi.cast("char *", name)
	end
end

local function hook_graph(g)
	local G = g.G

	G.exec_model = function(G, udata, ret, args)
		local model = g.models[ffi.string(udata)]
		return model.exf(ret, args) or C.FHK_OK
	end

	G.resolve_var = function(G, udata, value)
		local var = g.vars[ffi.string(udata)]
		return var.virtual(value) or C.FHK_OK
	end

	G.debug_desc_var = function(udata)
		return udata
	end

	G.debug_desc_model = function(udata)
		return udata
	end
end

local dgraph_mt = { __index = {} }

local function hook(G, fvars, fmodels, vars, models, exf, virtuals)
	local gvars, gmods = {}, {}

	for name,var in pairs(vars) do
		gvars[name] = {
			name    = name,
			fv      = fvars[name],
			ptype   = var.ptype,
			virtual = virtuals and virtual[name]
		}
	end

	for name,mod in pairs(models) do
		gmods[name] = {
			name    = name,
			params  = mod.params,
			returns = mod.returns,
			fm      = fmodels[name],
			exf     = exf and exf[name]
		}
	end

	local g = setmetatable({
		G        = G,
		vars     = gvars,
		models   = gmods
	}, dgraph_mt)

	hook_udata(fvars, fmodels)
	hook_graph(g)
	g:reset()
	return g
end

local function bminit(x)
	if type(x) == "number" then return {u8 = x} end
	if type(x) == "string" then return {[x] = 1} end
	return x or {u8 = 0}
end

function dgraph_mt.__index:reset(v, m)
	C.fhk_reset(self.G, ffi.new("fhk_vbmap", bminit(v)), ffi.new("fhk_mbmap", bminit(m)))
end

function dgraph_mt.__index:virtual(name, f)
	local v = self.vars[name]
	local desc = v.ptype.desc

	v.virtual = function(value)
		value[0] = C.vimportd(f(), desc)
	end
end

function dgraph_mt.__index:exf(name, f)
	local m = self.models[name]
	local atypes, rtypes = {}, {}
	for i,p in ipairs(m.params) do atypes[i] = self.vars[p].ptype.desc end
	for i,r in ipairs(m.returns) do rtypes[i] = self.vars[r].ptype.desc end

	m.exf = function(ret, args)
		local a = {}
		for i,t in ipairs(atypes) do
			a[i] = tonumber(C.vexportd(args[i-1], t))
		end

		local r = {f(unpack(a))}

		for i,t in ipairs(rtypes) do
			ret[i-1] = C.vimportd(r[i], t)
		end
	end
end

function dgraph_mt.__index:collectvs(names)
	local ret = ffi.new("struct fhk_var *[?]", #names)

	for i,name in ipairs(names) do
		ret[i-1] = self.vars[name].fv
	end

	return #names, ret
end

function dgraph_mt.__index:value(name)
	local v = self.vars[name]
	if self.G.v_bitmaps[v.fv.idx].has_value == 0 then
		return
	end

	return tonumber(C.vexportd(v.fv.value, v.ptype.desc))
end

function dgraph_mt.__index:collect_values(names)
	local ret = {}
	for _,name in ipairs(names) do
		ret[name] = self:value(name)
	end
	return ret
end

function dgraph_mt.__index:given_values(given)
	for name, val in pairs(given) do
		local fv = self.vars[name].fv
		local bitmap = self.G.v_bitmaps[fv.idx]
		bitmap.given = 1
		bitmap.has_value = 1
		fv.value = C.vimportd(val, self.vars[name].ptype.desc)
	end
end

function dgraph_mt.__index:err()
	local le = self.G.last_error
	local e = { err = le.err }

	if le.var ~= ffi.NULL then
		e.var = self.vars[ffi.string(le.var.udata)]
	end

	if le.model ~= ffi.NULL then
		e.model = self.models[ffi.string(le.model.udata)]
	end

	return e
end

function dgraph_mt.__index:solve(names)
	local nv, ys = self:collectvs(names)

	return function(given)
		self:reset()
		self:given_values(given)
		local r = C.fhk_solve(self.G, nv, ys)
		if r == C.FHK_OK then
			return true, self:collect_values(names)
		else
			return false, self:err()
		end
	end
end

function dgraph_mt.__index:reduce(names)
	local nv, ys = self:collectvs(names)
	local G = self.G
	local vmask = G:newvmask()
	local mmask = G:newmmask()
	local r = C.fhk_reduce(G, nv, ys, vmask, mmask)
	if r ~= C.FHK_OK then
		return false, self:err()
	end

	local size = C.fhk_subgraph_size(G, vmask, mmask)
	local H = ffi.gc(ffi.cast("struct fhk_graph *", C.malloc(size)), C.free)
	C.fhk_copy_subgraph(H, G, vmask, mmask)

	local hvars, hmodels = {}, {}

	for i=0, tonumber(H.n_var)-1 do
		local fv = H.vars[i]
		local name = ffi.string(fv.udata)
		local v = self.vars[name]
		hvars[name] = {
			name    = name,
			fv      = fv,
			ptype   = v.ptype,
			virtual = v.virtual
		}
	end

	for i=0, tonumber(H.n_mod)-1 do
		local fm = H.models[i]
		local name = ffi.string(fm.udata)
		local m = self.models[name]
		hmodels[name] = {
			name    = name,
			fm      = fm,
			params  = m.params,
			returns = m.returns,
			exf     = m.exf
		}
	end

	return true, setmetatable({
		G      = H,
		vars   = hvars,
		models = hmodels
	}, dgraph_mt)
end

-- solve will call back to Lua code via G hooks so this must not be compiled
require("jit").off(dgraph_mt.__index.solve)

--------------------------------------------------------------------------------

local function reportv(visited, ret, g, name, reason)
	if visited[name] then
		return
	end

	visited[name] = true

	local fv = g.vars[name].fv
	local bitmap = g.G.v_bitmaps[fv.idx]

	local r = {
		value  = g:value(name),
		desc   = name,
		reason = reason,
		given  = bitmap.given == 1,
		solved = bitmap.chain_selected == 1
	}

	table.insert(ret, r)

	if r.given then
		r.cost = 0
	end

	if r.solved and (not r.given) then
		local fm = fv.model
		r.model = ffi.string(fm.udata)
		r.cost = C.fhk_solved_cost(fm)

		for i=0, tonumber(fm.n_param)-1 do
			reportv(visited, ret, g, ffi.string(fm.params[i].udata), "parameter")
		end

		for i=0, tonumber(fm.n_check)-1 do
			reportv(visited, ret, g, ffi.string(fm.checks[i].var.udata), "constraint")
		end
	end
end

local function report(g, vars)
	local visited = {}
	local ret = {}

	for _,v in ipairs(vars) do
		reportv(visited, ret, g, v, "root")
	end

	return ret
end

local function maxcol(rep, field, max)
	max = max or 0

	for _,r in ipairs(rep) do
		local x = r[field]
		if x and #x > max then
			max = #x
		end
	end

	return max
end

local function print_report(rep)
	local desc_len = maxcol(rep, "desc", 20)
	local model_len = maxcol(rep, "model", 20)

	print(string.format("%-"..desc_len.."s   %-20s %-"..model_len.."s %-16s %s",
		"Variable",
		"Value",
		"Model",
		"Cost",
		"Status"
	))

	for _,r in ipairs(rep) do
		print(string.format("%-"..desc_len.."s = %-20s %-"..model_len.."s %-16s %s %s",
			r.desc,
			r.value,
			r.model or "",
			r.cost  or "",
			r.given and "given" or (r.solved and "solved" or "failed"),
			r.reason
		))
	end
end

--------------------------------------------------------------------------------

local function main(args)
	local cfg = conf.read(args.config)
	local g = hook(fhk.build_graph(cfg.fhk_vars, cfg.fhk_models))
	local exf = fhk.create_models(cfg.fhk_vars, cfg.fhk_models)
	for name,f in pairs(exf) do
		g.models[name].exf = f
	end

	local vars = aux.map(aux.split(args.vars), aux.trim)
	local solve = g:solve(vars)
	local given, values = aux.readcsv(args.input)

	local vs = {}

	for _,d in ipairs(values) do
		local vals = {}
		for i,v in ipairs(given) do
			vals[v] = d[i]
		end

		local ok, res = solve(vals)

		print("--------------------")

		if ok then
			print_report(report(g, vars))
		else
			-- TODO: print some detailed info
			print("Solver failed!")
		end
	end
end

return {
	cli_main = {
		main = main,
		usage = "[-c config] [-i input] [-f y1,y2,...,yN]",
		flags = {
			cli.opt("-c", "config"),
			cli.opt("-i", "input"),
			cli.opt("-f", "vars")
		}
	},
	hook = hook
}
