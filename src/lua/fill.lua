local ffi = require "ffi"
local conf = require "conf"
local hier = require "hier"

local function init_fhk(g, given_vars, fill_vars)
	local G = ffi.gc(ffi.new("struct fhk_graph"), ffi.C.fhk_graph_destroy)

	G.n_mod = g.n_models
	G.n_var = g.n_vars

	-- XXX: these callbacks probably should go in fhk_call.c

	G.resolve_virtual = function(G, udata, value)
		error("resolve_virtual called, this shouldn't happen")
		return 1
	end

	G.model_exec = function(G, udata, ret, arg)
		local m = ffi.cast("struct fhk_model_meta *", udata)
		return m.ei.exec(m.ei, ret, arg)
	end

	G.debug_desc_var = function(v)
		return ffi.cast("struct var_def *", v).name
	end

	G.debug_desc_model = function(m)
		return ffi.cast("struct fhk_model_meta *", m).name
	end

	ffi.C.fhk_graph_init(G)

	local gv_lookup = {}
	local given, solve = {}, {}

	for i=0, g.n_vars-1 do
		local vdef = ffi.cast("struct var_def *", g.vars[i].udata)
		gv_lookup[ffi.string(vdef.name)] = g.vars[i]
	end

	for _,v in ipairs(given_vars) do
		local x = gv_lookup[v]
		ffi.C.fhk_set_given(G, x)
		table.insert(given, x)
	end

	for _,v in ipairs(fill_vars) do
		local y = gv_lookup[v]
		ffi.C.fhk_set_solve(G, y)
		table.insert(solve, y)
	end

	return G, given, solve
end

local function copyvalue(v, val)
	local vdef = ffi.cast("struct var_def *", v.udata)
	local ptype = ffi.C.tpromote(vdef.type)

	--print(string.format("copyvalue %s <- %f", ffi.string(vdef.name), val))

	if ptype == ffi.C.PT_REAL then
		v.mark.value.r = val
	elseif ptype == ffi.C.PT_INT then
		v.mark.value.i = val
	elseif ptype == ffi.C.PT_BIT then
		v.mark.value.b = ffi.C.packenum(val)
	else
		error(string.format("unexpected ptype=%d", tonumber(ptype)))
	end
end

local function valuestr(v)
	local vdef = ffi.cast("struct var_def *", v.udata)
	local ptype = ffi.C.tpromote(vdef.type)

	if ptype == ffi.C.PT_REAL then
		return tonumber(v.mark.value.r)
	elseif ptype == ffi.C.PT_INT then
		return tonumber(v.mark.value.i)
	elseif ptype == ffi.C.PT_BIT then
		return ffi.C.unpackenum(v.mark.value.b)
	else
		error(string.format("unexpected ptype=%d", tonumber(ptype)))
	end
end

local function addchain(G, chain, visited, v)
	if visited[v.idx] then
		return
	end

	if G.v_bitmaps[v.idx].given == 1 then
		return
	end

	visited[v.idx] = true

	local vdef = ffi.cast("struct var_def *", v.udata)
	local model = v.mark.model
	local meta = ffi.cast("struct fhk_model_meta *", model.udata)

	table.insert(chain, string.format("%s:%s (cost: %f)",
		ffi.string(vdef.name),
		ffi.string(meta.name),
		tonumber(v.mark.min_cost)
	))

	for i=0, tonumber(model.n_check)-1 do
		local check = model.checks+i
		addchain(G, chain, visited, check.var)
	end

	for i=0, tonumber(model.n_param)-1 do
		addchain(G, chain, visited, model.params[i])
	end
end

local function getchain(G, solve)
	local chain = {}
	local visited = {}

	for i,v in ipairs(solve) do
		addchain(G, chain, visited, v)
	end

	return table.concat(chain, "\t")
end

local function get_given(obj)
	local givens = {}

	while obj do
		for _,f in ipairs(obj.fields) do
			table.insert(givens, f)
		end

		obj = obj.owner
	end

	return givens
end

local function copygiven(dest, obj, d)
	local ret = {}

	while obj do
		for j,v in ipairs(d) do
			print(string.format("* %s:%s = %f", obj.name, obj.fields[j], v))
			table.insert(ret, v)
		end

		obj = obj.owner
		d = d.owner
	end

	return ret
end

local function main(args)
	local env, data = conf.newconf()
	env.read(args.config)

	local vars, nv = conf.get_vars(data)
	local g = conf.get_fhk_graph(data, vars, nv)
	local data = hier.parse_file(args.input)
	local dobj = data.objs[args.fill.obj]
	local given_vars = get_given(dobj)
	local solve_vars = args.fill.fields
	local G, given, solve = init_fhk(g, given_vars, solve_vars)

	local out = io.open(args.output, "w")
	out:write(string.format("$\t%s\t-> %s \t; selected chain\n",
		table.concat(given_vars, "\t"),
		table.concat(solve_vars, "\t")
	))

	for id,d in pairs(dobj.data) do
		print("")
		local values = copygiven(given, dobj, d)

		for i,v in ipairs(values) do
			copyvalue(given[i], v)
		end

		print("--------------")
		local solved = {}

		for i,v in ipairs(solve) do
			local res = ffi.C.fhk_solve(G, v)
			if res ~= 0 then
				print("Solver failed on " .. solve_vars[i])
				out:write("(Solver failed)\n")
				goto continue
			end

			local model = v.mark.model
			local mmeta = ffi.cast("struct fhk_model_meta *", model.udata)
			local cost = v.mark.min_cost

			table.insert(solved, valuestr(v))
		end

		out:write(string.format("%s\t%s\t-> %s \t; %s\n",
			id,
			table.concat(values, "\t"),
			table.concat(solved, "\t"),
			getchain(G, solve)
		))

		::continue::
		ffi.C.fhk_reset(G, 0)
	end

	out:close()
end

return {
	main=main
}
