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

local function create_checks(checks)
	if #checks == 0 then
		return
	end

	local ret = ffi.new("struct fhk_check[?]", #checks)

	for i=0, #checks-1 do
		local c = ret+i
		local check = checks[i+1]
		c.var = check.var.fhk_var
		c.costs[C.FHK_COST_IN] = check.cost_in
		c.costs[C.FHK_COST_OUT] = check.cost_out
		copy_cst(c, check.cst)
	end

	return ret
end

local function create_params(params)
	if #params == 0 then
		return
	end

	local ret = ffi.new("struct fhk_var *[?]", #params)
	for i,p in ipairs(params) do
		ret[i-1] = p.fhk_var
	end

	return ret
end

local function create_models(models)
	if #models == 0 then
		return
	end

	local ret = ffi.new("struct fhk_model *[?]", #models)
	for i,m in ipairs(models) do
		ret[i-1] = m.fhk_model
	end

	return ret
end

local function retind(returns, y)
	-- we could build a lookup table here to avoid iterating but almost all models
	-- have 1-2 returns so it really doesn't matter
	for i,x in ipairs(returns) do
		if y == x then
			return i
		end
	end

	assert(false)
end

local function init_fhk_graph(arena, cfg)
	for _,m in pairs(cfg.fhk_models) do
		local fm = m.fhk_model

		fm.k = m.k
		fm.c = m.c

		local checks = create_checks(m.checks)
		C.fhk_alloc_checks(arena, fm, #m.checks, checks)

		local params = create_params(m.params)
		C.fhk_alloc_params(arena, fm, #m.params, params)

		C.fhk_alloc_returns(arena, fm, #m.returns)
	end

	for _,v in pairs(cfg.fhk_vars) do
		local fv = v.fhk_var

		local models = create_models(v.models)
		C.fhk_alloc_models(arena, fv, #v.models, models)

		for i,m in ipairs(v.models) do
			C.fhk_link_ret(m.fhk_model, fv, retind(m.returns, v)-1, i-1)
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
