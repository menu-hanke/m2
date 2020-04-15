local cli = require "cli"
local fhk = require "fhk"
local model = require "model"
local misc = require "misc"
local ffi = require "ffi"
local C = ffi.C

local debugger_mt = { __index={} }

local function hook(dbg)
	for name,fv in pairs(dbg.fvars) do
		fv.udata = ffi.cast("char *", name)
	end

	for name,fm in pairs(dbg.fmodels) do
		fm.udata = ffi.cast("char *", name)
	end

	local G = dbg.G

	G.exec_model = function(G, udata, ret, args)
		return dbg:model(ffi.string(udata), ret, args) or C.FHK_OK
	end

	G.resolve_var = function(G, udata, value)
		return dbg:var(ffi.string(udata), value) or C.FHK_OK
	end

	G.debug_desc_model = function(G, fm)
		return dbg:modelstr(ffi.string(ffi.cast("struct fhk_model *", fm).udata))
	end

	G.debug_desc_var = function(G, fv)
		return dbg:varstr(ffi.string(ffi.cast("struct fhk_var *", fv).udata))
	end

	-- the callbacks need to be freed when the debugger is freed but luajit doesn't
	-- support __gc on tables and I don't want to overwrite the __gc for G,
	-- so we need to do it this way and anchor the proxy to dbg
	local p = newproxy(true)
	getmetatable(p).__gc = function()
		G.exec_model:free()
		G.resolve_var:free()
		G.debug_desc_var:free()
		G.debug_desc_model:free()
	end
	dbg.proxy___ = p

	dbg:reset()
	return dbg
end

local function debugger(hooks, G, fvars, fmodels)
	return hook(setmetatable({
		hooks   = hooks or {},
		G       = G,
		fvars   = fvars,
		fmodels = fmodels,
		vars    = {},
		models  = {}
	}, debugger_mt))
end

----------------------------------------

function debugger_mt.__index:model(name, ret, args)
	local mod = self.models[name]
	if mod then
		return mod(ret, args)
	elseif self.hooks.model then
		return self.hooks.model(name, ret, args)
	else
		return -1
	end
end

function debugger_mt.__index:var(name, value)
	local var = self.vars[name]
	if var then
		return var(value)
	elseif self.hooks.var then
		return self.hooks.var(name, value)
	else
		return -1
	end
end

function debugger_mt.__index:modelstr(name)
	return self.hooks.modelstr and self.hooks.modelstr(name) or name
end

function debugger_mt.__index:varstr(name)
	return self.hooks.varstr and self.hooks.varstr(name) or name
end

----------------------------------------

-- type(x): nil           -> assume it's handled by a hook, just mark it as given
--          pvalue        -> mark as given value (pvalue)
--          anything else -> assume it's callable (virtual) and mark in vars
function debugger_mt.__index:given(name, x)
	local fv = self.fvars[name]
	fv.bitmap.given = 1

	if ffi.istype("pvalue", x) then
		fv.bitmap.has_value = 1
		fv.value = x
	elseif x ~= nil then
		self.vars[name] = x
	end
end

function debugger_mt.__index:read(name)
	local fv = self.fvars[name]
	if fv.bitmap.has_value == 1 then
		return fv.value
	end
end

function debugger_mt.__index:reset()
	C.fhk_reset(self.G, ffi.new("fhk_vbmap", {u8=0}), ffi.new("fhk_mbmap", {u8=0}))
end

-- this is similar to solver_failed_m, but they have different assumptions
-- (this graph is mapped using the debugger and hence has more information)
-- TODO?: this and solver_failed_m could be made into a single function?
function debugger_mt.__index:error()
	local err = self.G.last_error
	local context = {string.format("Solver failed: %s (%d)", self.G:error(), err.err)}

	if err.var ~= nil then
		local name = ffi.string(err.var.udata)
		table.insert(context, string.format("\t* Caused by this variable: %s", name))
		if self.vars[name] then
			table.insert(context, string.format("\t  -> mapping: %s", self.vars[name]))
		end
	end

	if err.model ~= nil then
		local name = ffi.string(err.model.udata)
		table.insert(context, string.format("\t* Caused by this model: %s", name))
		if self.models[name] then
			table.insert(context, string.format("\t  -> mapping: %s", self.models[name]))
		end
	end

	if self.hooks.error then
		local ctx = self.hooks.error(err)
		if ctx then
			table.insert(context, ctx)
		end
	end

	return table.concat(context, "\n")
end

function debugger_mt.__index:collect(names)
	local ys = ffi.new("struct fhk_var *[?]", #names)

	for i,name in ipairs(names) do
		ys[i-1] = self.fvars[name]
	end

	return #names, ys
end

function debugger_mt.__index:solve(names)
	return C.fhk_solve(self.G, self:collect(names)) == C.FHK_OK
end

function debugger_mt.__index:reduce(names)
	local vmask = self.G:newvmask()
	local mmask = self.G:newmmask()
	local nv, ys = self:collect(names)
	local ok = C.fhk_reduce(self.G, nv, ys, vmask, mmask) == C.FHK_OK
	return ok, self:collectmask(vmask, mmask)
end

function debugger_mt.__index:collectmask(vmask, mmask)
	local vnames = {}
	local mnames = {}

	for i=0, tonumber(self.G.n_var)-1 do
		if vmask[i] ~= 0 then
			table.insert(vnames, ffi.string(self.G.vars[i].udata))
		end
	end

	for i=0, tonumber(self.G.n_mod)-1 do
		if mmask[i] ~= 0 then
			table.insert(mnames, ffi.string(self.G.models[i].udata))
		end
	end

	return vnames, mnames
end

-- these call Lua -> C -> Lua, which should not be compiled
jit.off(debugger_mt.__index.solve)
jit.off(debugger_mt.__index.reduce)

--------------------------------------------------------------------------------

local function tomodel(apv, rpv, f)
	return function(ret, args)
		local a = {}
		for i,pv in ipairs(apv) do
			a[i] = args[i-1][pv]
		end

		local r = {f(unpack(a))}

		for i,pv in ipairs(rpv) do
			ret[i-1][pv] = r[i]
		end
	end
end

local function tovar(pv, f)
	return function(value)
		value[pv] = f()
	end
end

--------------------------------------------------------------------------------

local function adj(s, len)
	if #s > len then return s:sub(1, len) end
	if #s < len then return s .. (" "):rep(len-#s) end
	return s
end

local function printtable(tab, opt)
	local colmax = {}

	for _,row in ipairs(tab) do
		for c,s in ipairs(row) do
			colmax[c] = math.max(s and #s or 0, colmax[c] or 0)
		end
	end

	local ret = {}

	for r,row in ipairs(tab) do
		if r > 1 then table.insert(ret, "\n") end
		for c,s in ipairs(row) do
			if c > 1 then table.insert(ret, "    ") end
			table.insert(ret, adj(s or "", colmax[c]))
		end
	end

	return table.concat(ret, "")
end

local function bit(b, value)
	return value == 1 and b or " "
end

local function reportv(dbg, mapper, name)
	local fv = dbg.fvars[name]

	if fv.bitmap.has_bound == 0 then
		return -- not relevant
	end

	return {
		name,
		fv.bitmap.has_value == 1 and ""..mapper:export(name, dbg:read(name), "class"),
		fv.bitmap.chain_selected == 1 and ffi.string(fv.model.udata),
		fv.bitmap.given == 0 and (
			fv.bitmap.chain_selected == 1 and
				string.format("%.4f", fv.cost_bound[0]) or
				string.format("[%.4f, %.4f]", fv.cost_bound[0], fv.cost_bound[1])
		),
		string.format("%s%s%s%s%s%s   %s%s%s%s",
			bit("g", fv.bitmap.given),
			bit("m", fv.bitmap.mark),
			bit("s", fv.bitmap.chain_selected),
			bit("v", fv.bitmap.has_value),
			bit("b", fv.bitmap.has_bound),
			bit("t", fv.bitmap.target),
			fv.bitmap.chain_selected == 1 and bit("b", fv.model.bitmap.has_bound) or " ",
			fv.bitmap.chain_selected == 1 and bit("s", fv.model.bitmap.chain_selected) or " ",
			fv.bitmap.chain_selected == 1 and bit("r", fv.model.bitmap.has_return) or " ",
			fv.bitmap.chain_selected == 1 and bit("m", fv.model.bitmap.mark) or " "
		)
	}
end

local function report(dbg, mapper)
	local ret = {}

	for name,_ in pairs(dbg.fvars) do
		local v = reportv(dbg, mapper, name)
		if v then
			table.insert(ret, v)
		end
	end

	table.sort(ret, function(a, b) return a[1] < b[1] end)

	return printtable({
		{"Variable", "Value", "Model", "Cost", "vbits  : mbits"},
		{"--------", "-----", "-----", "----", "------   -----"},
		unpack(ret)
	})
end

local function runinput(dbg, mapper, input, names)
	local given, values = misc.readcsv(input)

	for _,d in ipairs(values) do
		dbg:reset()

		for i,name in ipairs(given) do
			dbg:given(name, mapper:import(name, tonumber(d[i]) or d[i]))
		end

		if not dbg:solve(names) then
			print(dbg:error())
		else
			print(report(dbg, mapper))
		end

		print() print(("-"):rep(70)) print()
	end
end

----------------------------------------

local function lazymod(def, mapper)
	local models = {}

	return function(name, ...)
		if not models[name] then
			models[name] = fhk.create_model(
				def.models[name],
				mapper,
				def.calibs[name] ~= nil,
				conf
			)

			if def.calibs[name] then
				fhk.calibrate_model(models[name], def.calibs[name])
			end
		end

		return models[name](...)
	end
end

local function moderr(err)
	return err.model ~= nil and model.error()
end

local function main(args)
	local def = fhk.def()
	local env = fhk.def_env(def)
	env.read(args.graph or "Melafile.g.lua")
	local mapper = fhk.mapper():hint(def)
	local dbg = debugger({model=lazymod(def, mapper), error=moderr}, fhk.build_graph(def))

	if args.input then
		runinput(
			dbg,
			mapper,
			args.input or error("Missing input (-i)"),
			misc.map(misc.split(args.solve or error("Missing targets (-s)")), misc.trim)
		)
	else
		-- TODO: interactive mode goes here
	end
end

return {
	cli_main = {
		main = main,
		usage = "[graph] [-i input] [-s y1,y2,...,yN]",
		flags = {
			cli.positional("graph"),
			cli.opt("-i", "input"),
			cli.opt("-s", "solve")
		}
	},

	debugger = debugger,
	tomodel  = tomodel,
	tovar    = tovar
}
