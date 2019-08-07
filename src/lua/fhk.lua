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

local function create_ugraph(_sim, _lex, G)
	local u = C.u_create(_sim, _lex, G)

	for _,fv in pairs(data.fhk_vars) do
		if fv.kind == "var" then
			C.u_link_var(u, fv.fhk_var, fv.src.obj.lexobj, fv.src.lexvar)
		elseif fv.kind == "env" then
			C.u_link_env(u, fv.fhk_var, fv.src.lexenv)
		elseif fv.kind == "computed" then
			C.u_link_computed(u, fv.fhk_var, fv.src.name)
		end
	end

	for _,fm in pairs(data.fhk_models) do
		C.u_link_model(u, fm.fhk_model, fm.name, fm.ex_func)
	end

	return u
end

local function create_uset(ugraph, objid, varids)
	local c_varids = copyarray("lexid[?]", #varids)
	return C.uset_create_vars(u, objid, #varids, varids)
end

return {
	init_fhk_graph = init_fhk_graph,
	create_upgrah  = create_ugraph,
	create_uset    = create_uset
}
