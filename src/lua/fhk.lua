local ffi = require "ffi"
local exec = require "exec"
local C = ffi.C

local function copy_ival_cst(check, a, b)
	check.cst.type = C.FHK_RIVAL
	check.cst.rival.min = a
	check.cst.rival.max = b
end

local function copy_set_cst(check, values)
	local mask = 0

	for _,v in ipairs(values) do
		if v<0 or v>63 then
			error(string.format("invalid bitset value: %d", v))
		end

		-- XXX: not sure if lua actually has 64-bit integers,
		-- maybe this should be done in C
		mask = bit.bor(mask, tonumber(C.packenum(v)))
	end

	check.cst.type = C.FHK_BITSET
	check.cst.setmask = mask
end

local function copy_cst(check, cst)
	if cst.type == "ival" then
		copy_ival_cst(check, cst.a, cst.b)
	elseif cst.type == "set" then
		copy_set_cst(check, cst.values)
	else
		error(string.format("invalid cst type '%s'", cst.type))
	end
end

local function create_checks(model, checks, malloc)
	model.n_check = #checks

	if #checks == 0 then
		return
	end

	model.checks = malloc(ffi.sizeof("struct fhk_check[?]", model.n_check))

	for i=0, #checks-1 do
		local c = model.checks+i
		local check = checks[i+1]
		c.var = check.var.fhk_var
		c.costs[C.FHK_COST_IN] = check.cost_in
		c.costs[C.FHK_COST_OUT] = check.cost_out
		copy_cst(c, check.cst)
	end
end

local function init_fhk_graph(G, data, malloc)
	for _,m in pairs(data.fhk_models) do
		local fm = m.fhk_model

		fm.k = m.k
		fm.c = m.c

		create_checks(fm, m.checks, malloc)

		-- TODO
		fm.may_fail = 1

		fm.n_param = #m.params
		fm.params = malloc(ffi.sizeof("struct fhk_var *[?]", fm.n_param))
		for i,p in ipairs(m.params) do
			fm.params[i-1] = p.fhk_var
		end
	end

	for _,v in pairs(data.fhk_vars) do
		local fv = v.fhk_var

		fv.n_mod = #v.models
		fv.models = malloc(ffi.sizeof("struct fhk_model *[?]", fv.n_mod))
		for i,m in ipairs(v.models) do
			fv.models[i-1] = m.fhk_model
		end
	end
end

-------------------------

local ugraph = {}
local ugraph_mt = {__index=ugraph}

local function create_ugraph(G, cfg)
	local u = ffi.gc(C.u_create(G), C.u_destroy)

	for _,fv in pairs(cfg.fhk_vars) do
		if fv.kind == "computed" then
			C.u_add_comp(u, fv.fhk_var, fv.src.name)
		end
	end

	for _,fm in pairs(cfg.fhk_models) do
		C.u_add_model(u, fm.ex_func, fm.fhk_model, fm.name)
	end

	return setmetatable({ _u=u }, ugraph_mt)
end

function ugraph:add_world(cfg, world)
	self.obj = {}
	self.env = {}

	for name,obj in pairs(cfg.objs) do
		local wobj = world.obj[name]
		local uobj = C.u_add_obj(self._u, wobj, name)
		self.obj[name] = uobj

		for vname,_ in pairs(obj.vars) do
			local fv = cfg.fhk_vars[vname]
			if fv then
				C.u_add_var(self._u, uobj, world.var[vname], fv.fhk_var, vname)
			end
		end
	end

	for name,wenv in pairs(world.env) do
		local fv = cfg.fhk_vars[name]
		if fv then
			self.env[name] = C.u_add_env(self._u, wenv, fv.fhk_var, name)
		end
	end
end

function ugraph:obj_uset(uobj, _world, varids)
	local c_varids = copyarray("lexid[?]", varids)
	return C.uset_create_obj(self._u, uobj, _world, #varids, c_varids)
end

function ugraph:update(s)
	s:update(self._u)
end

-------------------------

local uset_obj = {}
local uset_obj_mt = {__index=uset_obj, __gc=C.uset_destroy_obj}

function uset_obj:update(_u)
	C.uset_update_obj(_u, self)
end

ffi.metatype("uset_obj", uset_obj_mt)

-------------------------

return {
	init_fhk_graph = init_fhk_graph,
	create_ugraph  = create_ugraph
}
