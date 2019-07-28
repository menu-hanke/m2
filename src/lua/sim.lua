local ffi = require "ffi"
local lex = require "lex"
local exec = require "exec"

local sim, slice, ufhk = {}, {}, {}
local sim_mt, slice_mt, ref_mt, ufhk_mt = { __index = sim }, { __index = slice }, {},
	{ __index = ufhk }

local function init_objns(lex)
	local objs = lex.objs
	local ret = {}

	for i=0, tonumber(objs.n)-1 do
		local obj = objs.data+i
		local vars = {}

		for j=0, tonumber(obj.vars.n)-1 do
			local var = obj.vars.data[j]

			vars[ffi.string(var.name)] = {
				id=j,
				def=var
			}
		end

		ret[ffi.string(obj.name)] = {
			def=obj,
			vars=vars
		}
	end

	return ret
end

local function create(lex)
	local _sim = ffi.gc(ffi.C.sim_create(lex.lex), ffi.C.sim_destroy)
	return setmetatable({
		_sim=_sim,
		objs=init_objns(lex.lex)
	}, sim_mt)
end

local function newref(sim, ref, obj)
	return setmetatable({ _sim=sim, _ref=ref, _obj=obj }, ref_mt)
end

local function getuprefidx(def, udef)
	for i=0, tonumber(def.uprefs.n)-1 do
		if def.uprefs.data[i].ref == udef then
			return i
		end
	end

	assert(false)
end

local function slice1(ref)
	local slice = ffi.new("sim_slice")
	ref = ref._ref
	slice.vec = ref.vec
	slice.from = ref.idx
	slice.to = ref.idx+1
	return setmetatable({ _slice=slice }, slice_mt)
end

function sim:allocv(objname, n, ...)
	local slice = ffi.new("sim_slice[1]")

	local upref_ptrs = {...}
	local uprefs = nil
	if #upref_ptrs > 0 then
		uprefs = ffi.new("sim_objref[?]", #upref_ptrs)
		for i,p in ipairs(upref_ptrs) do
			ffi.copy(uprefs+i-1, p._ref, ffi.sizeof("sim_objref"))
		end
	end

	ffi.C.sim_allocv(self._sim, slice, self.objs[objname].def.id, uprefs, n)
	return setmetatable({ _slice=slice+0 }, slice_mt)
end

function sim:alloc1(objname, ...)
	local slice = self:allocv(objname, 1, ...)
	local ref = ffi.cast("sim_objref *", slice._slice)
	local obj = self.objs[objname]

	return newref(self, ref, obj)
end

function sim:iter(objname, upref)
	local iter = ffi.new("sim_iter[1]")
	local obj = self.objs[objname]
	local r = ffi.C.sim_first(self._sim, iter, obj.def.id,
		upref and upref._ref,
		upref and getuprefidx(obj.def, upref._obj.def) or -1
	)

	local ref = ffi.new("sim_objref[1]")

	return function()
		if r ~= ffi.C.SIM_ITER_END then
			ffi.copy(ref, iter[0].ref, ffi.sizeof("sim_objref"))
			local ret = newref(self, ref+0, obj)
			r = ffi.C.sim_next(iter)
			return ret
		end
	end
end

function sim:enter()
	return ffi.C.sim_enter(self._sim)
end

function sim:rollback()
	return ffi.C.sim_rollback(self._sim)
end

function sim:exit()
	return ffi.C.sim_exit(self._sim)
end

function sim:create_fhk_update(graph, lex)
	local exf = {}

	local u = ffi.gc(ffi.C.ufhk_create(lex.lex), function(u)
		for _,f in ipairs(exf) do
			exec.destroy(f)
		end
		ffi.C.ufhk_destroy(u)
	end)

	local g_vars = {}
	for i,v in ipairs(graph.vars) do
		g_vars[v.name] = graph.c_vars[i-1]
	end

	for i,lv in ipairs(lex.vars) do
		if g_vars[lv.name] then
			ffi.C.ufhk_set_var(u, i-1, g_vars[lv.name])
		end
	end

	for i,m in ipairs(graph.models) do
		local f = exec.from_model(m)
		table.insert(exf, f)
		ffi.C.ufhk_set_model(u, m.name, f, graph.c_models[i-1])
	end

	ffi.C.ufhk_set_graph(u, graph.G)

	return setmetatable({
		_u=u,
		sim=self
	}, ufhk_mt)
end

function ref_mt:__index(vname)
	local var = self._obj.vars[vname]
	local pv = ffi.C.sim_read1p(self._sim._sim, self._ref, self._obj.def.id, var.id)
	return lex.frompvalue_s(pv, ffi.C.tpromote(var.def.type))
end

function ref_mt:__newindex(vname, val)
	local var = self._obj.vars[vname]
	local pv = lex.topvalue_s(val, ffi.C.tpromote(var.def.type))
	ffi.C.sim_write1p(self._sim._sim, self._ref, self._obj.def.id, var.id, pv)
end

function ufhk:create_uset(objname, ...)
	local vnames = {...}
	local vs = ffi.new("lexid[?]", #vnames)
	local obj = self.sim.objs[objname]

	for i,v in ipairs(vnames) do
		vs[i-1] = obj.vars[v].id
	end

	local uset = ffi.gc(ffi.C.uset_create(self._u, obj.def.id, #vnames, vs), ffi.C.uset_destroy)

	return {
		_uset=uset,
		_vs=vs
	}
end

function ufhk:update(uset)
	return ffi.C.ufhk_update(self._u, uset._uset, self.sim._sim)
end

function ufhk:update_slice(slice, uset)
	return ffi.C.ufhk_update_slice(self._u, uset._uset, slice._slice)
end

return {
	create=create,
	slice1=slice1
}
