local cli = require "cli"
local ffi = require "ffi"
local conf = require "conf"
local fhk = require "fhk"
local typing = require "typing"

local function hook_udata(vars, models)
	for name,fv in pairs(vars) do
		fv.fhk_var.udata = ffi.cast("char *", name)
	end

	for name,fm in pairs(models) do
		fm.fhk_model.udata = ffi.cast("char *", name)
	end
end

local function hook_graph(g)
	local G = g.G

	G.exec_model = function(G, udata, ret, args)
		local name = ffi.string(udata)
		return g.exf[name](ret, args) or ffi.C.FHK_OK
	end

	G.resolve_var = function(G, udata, value)
		assert(false)
	end

	-- G.chain_solved = nil

	G.debug_desc_var = function(udata)
		return udata
	end

	G.debug_desc_model = function(udata)
		return udata
	end
end

local dgraph_mt = { __index = {} }

local function hook(G, vars, models)
	local g = setmetatable({
		G      = G,
		vars   = vars,
		models = models,
		exf    = {}
	}, dgraph_mt)

	hook_udata(vars, models, exf)
	hook_graph(g)

	-- XXX remove when stable removed
	local bitmap = ffi.new("fhk_vbmap", {stable=1})
	ffi.C.bm_or64(ffi.cast("bm8 *", G.v_bitmaps), G.n_var, ffi.C.bmask8(bitmap.u8))
	g:reset()

	return g
end

function dgraph_mt.__index:create_models(calib)
	local exf = fhk.create_models(self.vars, self.models, calib)
	for name,f in pairs(exf) do
		self.exf[name] = f
	end
end

function dgraph_mt.__index:reset()
	ffi.C.fhk_reset(self.G, ffi.new("fhk_vbmap", {given=1, stable=1}), ffi.new("fhk_mbmap"))
end

function dgraph_mt.__index:given(names)
	ffi.C.fhk_reset(self.G, ffi.new("fhk_vbmap", {stable=1}), ffi.new("fhk_mbmap"))
	for _,name in ipairs(names) do
		local fv = self.vars[name].fhk_var
		self.G.v_bitmaps[fv.idx].given = 1
	end
end

function dgraph_mt.__index:vpointers(names)
	local ret = ffi.new("struct fhk_var *[?]", #names)
	for i,name in ipairs(names) do
		ret[i-1] = self.vars[name].fhk_var
	end
	return #names, ret
end

function dgraph_mt.__index:setvalues(values)
	for name,value in pairs(values) do
		local fv = self.vars[name].fhk_var
		self.G.v_bitmaps[fv.idx].has_value = 1
		fv.value = ffi.C.vimportd(value, self.vars[name].type.desc)
	end
end

function dgraph_mt.__index:value(name)
	local v = self.vars[name]
	if self.G.v_bitmaps[v.fhk_var.idx].has_value == 0 then
		return
	end
	return tonumber(ffi.C.vexportd(v.fhk_var.value, self.vars[name].type.desc))
end

function dgraph_mt.__index:solve(n, ptrs)
	return ffi.C.fhk_solve(self.G, n, ptrs)
end

-- solve will call back to Lua code via G hooks so this must not be compiled
require("jit").off(dgraph_mt.__index.solve)

--------------------------------------------------------------------------------

local function reportv(visited, ret, g, name, reason)
	if visited[name] then
		return
	end

	visited[name] = true

	local fv = g.vars[name].fhk_var
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
		r.cost = fv.min_cost

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

local function readcsv(fname)
	local f = io.open(fname)
	local header = map(split(f:read()), trim)
	local data = {}

	for l in f:lines() do
		local d = map(split(l), tonumber)
		if #d ~= #header then
			error(string.format("Invalid line: %s (expected %d values but have %d)",
				l, #d, #header))
		end
		table.insert(data, d)
	end

	f:close()

	return header, data
end

--------------------------------------------------------------------------------

local function main(args)
	local cfg = conf.read(args.config)
	local g = hook(fhk.build_graph(cfg.fhk_vars, cfg.fhk_models))
	g:create_models()

	local ns, solve = g:vpointers(args.vars)
	local given, values = readcsv(args.input)
	g:given(given)

	local vs = {}

	for _,d in ipairs(values) do
		g:reset()

		for i,v in ipairs(given) do
			vs[v] = d[i]
		end

		g:setvalues(vs)
		g:solve(ns, solve)

		print("--------------------")
		local rep = report(g, args.vars)
		print_report(rep)
	end
end

return {
	flags = {
		c = cli.opt("config"),
		i = cli.opt("input"),
		f = function(ret, ai) ret.vars = map(split(ai()), trim) end
	},
	main = main,
	hook = hook
}
