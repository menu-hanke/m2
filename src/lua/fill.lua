local ffi = require "ffi"
local conf = require "conf"

local function trim(str)
	-- ignore second return val
	str = str:gsub("^%s*(.*)%s*$", "%1")
	return str
end

local function split_map(str, map)
	local ret = {}
	for s in str:gmatch("[^,]+") do
		table.insert(ret, map(s))
	end
	return ret
end

local function read_input(input)
	local f = io.open(input)
	local cols = split_map(f:read(), trim)
	local data = {}

	for l in f:lines() do
		table.insert(data, split_map(l, tonumber))
	end

	f:close()
	return cols, data
end

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
	local ptype = ffi.C.get_ptype(vdef.type)

	if ptype == ffi.C.T_REAL then
		v.mark.value.r = val
	elseif ptype == ffi.C.T_INT then
		v.mark.value.i = val
	elseif ptype == ffi.C.T_BIT then
		v.mark.value.b = ffi.C.get_bit_enum(val)
	else
		error(string.format("unexpected ptype=%d", tonumber(ptype)))
	end
end

local function valuestr(v)
	local vdef = ffi.cast("struct var_def *", v.udata)
	local ptype = ffi.C.get_ptype(vdef.type)

	if ptype == ffi.C.T_REAL then
		return tonumber(v.mark.value.r)
	elseif ptype == ffi.C.T_INT then
		return tonumber(v.mark.value.i)
	elseif ptype == ffi.C.T_BIT then
		return ffi.C.get_enum_bit(v.mark.value.b)
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

local function main(args)
	local env, data = conf.newconf()
	env.read(args.config)

	local vars, nv = conf.get_vars(data)
	local g = conf.get_fhk_graph(data, vars, nv)
	local given_vars, in_data = read_input(args.input)
	local fill_vars = split_map(args.fill_vars, trim)

	local G, given, solve = init_fhk(g, given_vars, fill_vars)

	local out = io.open(args.output, "w")
	out:write(string.format("%s\t-> %s \t; selected chain\n",
		table.concat(given_vars, "\t"),
		table.concat(fill_vars, "\t")
	))

	for _,values in ipairs(in_data) do
		print("")

		for i,v in ipairs(given_vars) do
			copyvalue(given[i], values[i])
			print(string.format("* %s = %f", v, values[i]))
		end

		print("--------------")
		local solved = {}

		for i,v in ipairs(solve) do
			local res = ffi.C.fhk_solve(G, v)
			if res ~= 0 then
				print("Solver failed on " .. fill_vars[i].name)
				out:write("(Solver failed)\n")
				goto continue
			end

			local model = v.mark.model
			local mmeta = ffi.cast("struct fhk_model_meta *", model.udata)
			local cost = v.mark.min_cost

			table.insert(solved, valuestr(v))
		end

		out:write(string.format("%s\t-> %s \t; %s\n",
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
