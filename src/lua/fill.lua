local ffi = require "ffi"
local lex = require "lex"
local sim = require "sim"
local conf = require "conf"
local exec = require "exec"
local objparse = require "objparse"

-- TODO: since this filling program is for filling data and testing models/chains, these
-- structs could contain more debug info such as:
-- * number of calls
-- * execution times
-- * different values / distribution of values
-- etc. (this could even be expanded into a model chain "debugger")
ffi.cdef [[
	typedef struct fvar_info {
		void *udata;
		const char *desc;
		int graph_idx;
	} fvar_info;

	typedef struct fmodel_info {
		void *udata;
		const char *desc;
		int graph_idx;
	} fmodel_info;
]]

local function hook(graph)
	local arena = ffi.C.arena_create(1024)
	local fvars = ffi.cast("fvar_info *", ffi.C.arena_malloc(arena,
		ffi.sizeof("fvar_info[?]", #graph.vars)))
	local fmods = ffi.cast("fmodel_info*", ffi.C.arena_malloc(arena,
		ffi.sizeof("fmodel_info[?]", #graph.models)))

	for i=0, #graph.vars-1 do
		local fv = fvars+i
		local cv = graph.c_vars+i
		fv.udata = cv.udata
		fv.graph_idx = i+1
		fv.desc = arena_copystring(arena, graph.vars[i+1].name)
		cv.udata = fv
	end

	for i=0, #graph.models-1 do
		local fm = fmods+i
		local cm = graph.c_models+i
		fm.udata = cm.udata
		fm.graph_idx = i+1
		fm.desc = arena_copystring(arena, graph.models[i+1].name)
		cm.udata = fm
	end

	local G = graph.G
	local resolve_virtual = G.resolve_virtual
	local model_exec = G.model_exec
	local ddv = G.debug_desc_var
	local ddm = G.debug_desc_model

	G.resolve_virtual = function(G, udata, value)
		local fv = ffi.cast("fvar_info *", udata)
		return resolve_virtual(G, fv.udata, value)
	end

	G.model_exec = function(G, udata, ret, arg)
		local fm = ffi.cast("fmodel_info *", udata)
		return model_exec(G, fm.udata, ret, arg)
	end

	G.debug_desc_var = function(udata)
		local fv = ffi.cast("fvar_info *", udata)
		return fv.desc
		--return ddv(fv.udata)
	end

	G.debug_desc_model = function(udata)
		local fm = ffi.cast("fmodel_info *", udata)
		return fm.desc
		--return ddm(fm.udata)
	end

	return {
		arena=arena,
		fvars=fvars,
		fmods=fmods
	}
end

local function getchain(ret, graph, c_var, vtype)
	local fv = ffi.cast("fvar_info *", c_var.udata)
	local var = graph.vars[fv.graph_idx]

	if ret[var] then
		return
	end

	ret[var] = true

	local bitmap = graph.G.v_bitmaps[c_var.idx]
	local model, c_model, fm

	if bitmap.given == 1 then
		model = ""
	else
		c_model = c_var.mark.model
		fm = ffi.cast("fmodel_info *", c_model.udata)
		model = graph.models[fm.graph_idx].name
	end

	local cost = c_var.mark.min_cost

	table.insert(ret, string.format("%-20s = %-10s %-20s %-16f %s %s",
		var.name,
		lex.frompvalue_s(c_var.mark.value, ffi.C.tpromote(var.type)),
		model,
		cost,
		(bitmap.solve == 1) and "solved"
			or (bitmap.given == 1) and "given"
			or "computed",
		vtype
	))

	if bitmap.given == 1 then
		return
	end

	for i=0, tonumber(c_model.n_param)-1 do
		getchain(ret, graph, c_model.params[i], "param")
	end

	for i=0, tonumber(c_model.n_check)-1 do
		getchain(ret, graph, c_model.checks[i].var, "constraint")
	end
end

local function print_chain(graph, c_vars)
	local chain = {}
	for _,cv in ipairs(c_vars) do
		getchain(chain, graph, cv, "root")
	end

	print(string.format("%-20s   %-10s %-20s %-16s %s",
		"Variable",
		"Value",
		"Model",
		"Cost",
		"Status"
	))
	print(table.concat(chain, "\n"))
end

local function getcvars(graph, names)
	local vars = {}
	for i,v in ipairs(graph.vars) do
		vars[v.name] = graph.c_vars+i-1
	end

	local ret = {}
	for i,n in ipairs(names) do
		ret[i] = vars[n]
	end

	return ret
end

local function main(args)
	local data = conf.read(args.config)
	local l = conf.get_lexicon(data)
	local graph = conf.get_fhk_graph(data)
	local S = sim.create(l)
	local upd = S:create_fhk_update(graph, l)
	local h = hook(graph)
	objparse.read_vecs(S, data, args.input)
	local uset = upd:create_uset(args.fill.obj, unpack(args.fill.fields))
	local solve_cvars = getcvars(graph, args.fill.fields)
	
	if args.batch then
		upd:update(uset)
	else
		for o in S:iter(args.fill.obj) do
			local slice = sim.slice1(o)
			upd:update_slice(slice, uset)
			print_chain(graph, solve_cvars)
			print()
		end
	end
end

return {
	main=main
}
