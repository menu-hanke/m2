local ffi = require "ffi"
local lex = require "lex"
local vmath = require "vmath"
local C = ffi.C

local function vecn(v)
	return tonumber(v.nuse)
end

local function vece(v, i)
	return v.data+i
end

local function delegate(owner, f)
	return function(...)
		return f(owner, ...)
	end
end

-------------------------

local chain = {}
local chain_mt = { __index = chain }
local callback_mt = {}

local function create_chain(name)
	return setmetatable({}, chain_mt)
end

local function create_callback(f, prio)
	return setmetatable({f=f, prio=prio}, callback_mt)
end

function chain:add(cb)
	table.insert(self, cb)
	self:sort()
end

function chain:sort()
	table.sort(self)
end

function callback_mt:__lt(other)
	return self.prio < other.prio
end

function callback_mt:__call(...)
	return self.f(...)
end

-------------------------

local objvec = {}

function objvec:pvec(varid)
	local ret = ffi.new("struct pvec")
	C.sim_obj_pvec(ret, self, varid)
	return vmath.vec(ret)
end

ffi.metatype("sim_objvec", {__index=objvec})

-------------------------

local envf = setmetatable({}, {__index=_G})

function envf.choice(id, chain, ...)
	return {id=id, chain=chain, args={...}}
end

function envf.branch(choices)
	return "branch", choices
end

-------------------------

local sim = {}
local sim_mt = { __index = sim }
local chaintable_mt = {}

local function create_env_lex(env, _sim, lex)
	local id = setmetatable({}, {__index=function(id, name)
		error(string.format("No id matching name '%s'", name))
	end})

	local env_ = setmetatable({}, {__index=function(env_, name)
		error(string.format("No env matching name '%s'", name))
	end})

	for i=0, vecn(lex.objs)-1 do
		local o = vece(lex.objs, i)
		id[ffi.string(o.name)] = o.id

		for j=0, vecn(o.vars)-1 do
			local v = vece(o.vars, j)
			id[ffi.string(v.name)] = v.id
		end
	end

	for i=0, vecn(lex.envs)-1 do
		local e = vece(lex.envs, i)
		env_[ffi.string(e.name)] = C.sim_get_env(_sim, i)
	end

	env.id = id
	env.env = env_
end

local function create_sim(lex)
	local env = setmetatable({}, {__index=envf})
	local chains = setmetatable({}, chaintable_mt)
	local _sim = ffi.gc(C.sim_create(lex), C.sim_destroy)
	create_env_lex(env, _sim, lex)

	local sim = setmetatable({
		env=env,
		chains=chains,
		_sim=_sim
	}, sim_mt)

	env.sim = sim
	env.on = delegate(sim, sim.on)

	return sim
end

local function chain_branch(S, choices)
	local ids = ffi.new("sim_branchid[?]", #choices)
	local chains = {}
	for i,v in ipairs(choices) do
		chains[v.id] = {chain=S.chains[v.chain]}
		ids[i-1] = v.id
	end

	local _sim = S._sim
	local first = C.sim_branch(_sim, #choices, ids)
	return function()
		local ret

		if first then
			ret = first
			first = nil
		else
			ret = C.sim_next_branch(_sim)
		end

		if ret ~= 0 then
			return chains[tonumber(ret)]
		end

		C.sim_exit(_sim)
	end
end

local function invoke_next_chain(S, chain, idx, continue)
	if not chain[idx] then
		return continue()
	end

	local ctl, info = chain[idx]()
	
	if ctl == "branch" then
		local cont = function()
			invoke_next_chain(S, chain, idx+1, continue)
		end

		for c in chain_branch(S, info) do
			invoke_next_chain(S, c.chain, 1, cont)
		end

		return
	else
		assert(not ctl)
	end

	invoke_next_chain(S, chain, idx+1, continue)
end

function sim:run_script(fname)
	local f, err = loadfile(fname, nil, self.env)
	f()
end

function sim:on(event, f, prio)
	if not prio then
		-- allow specifying prio in event string like "event#prio"
		local e,p = event:match("(.-)#([%-%+]?%d+)")
		if e then
			event = e
			prio = tonumber(p)
		else
			prio = 0
		end
	end

	self.chains[event]:add(create_callback(f, prio))
end

function sim:run(event, continue, ...)
	return invoke_next_chain(self, self.chains[event], 1, continue, ...)
end

function sim:evec(env)
	local pvec = ffi.new("struct pvec")
	C.sim_env_pvec(pvec, env)
	return vmath.vec(pvec)
end

function sim:swap_env(env)
	local pvec old = ffi.new("struct pvec")
	local pvec new = ffi.new("struct pvec")
	C.sim_env_pvec(old. env)
	new.type = old.type
	new.n = old.n
	new.data = C.sim_alloc_env(self._sim, env)
	C.sim_env_swap(self._sim, env, new.data)
	return vmath.vec(old), vmath.vec(new)
end

function sim:swap_band(vec, varid)
	local pvec old = ffi.new("struct pvec")
	local pvec new = ffi.new("struct pvec")
	C.sim_obj_pvec(old, vec, varid)
	new.type = old.type
	new.n = old.n
	new.data = C.sim_alloc_band(self._sim, vec, varid)
	C.sim_obj_swap(self._sim, vec, varid, new.data)
	return vmath.vec(old), vmath.vec(new)
end

function chaintable_mt:__index(k)
	local ret = create_chain(k)
	self[k] = ret
	return ret
end

function sim:create_objs(objid, pos)
	local c_pos, n = copyarray("gridpos[?]", pos)
	local refs = ffi.new("sim_objref[?]", n)
	C.sim_allocv(self._sim, refs, objid, n, c_pos)
	return refs
end

function sim:del_objs(refs)
	local r, n = copyarray("sim_objref[?]", refs)
	C.sim_deletev(self._sim, n, r)
end

function sim:each_objvec(objid, f)
	local grid = C.sim_get_objgrid(self._sim, objid)
	local max = C.grid_max(grid.order)

	for i=0, tonumber(max)-1 do
		local vec = ffi.cast("sim_objvec *", C.grid_data(grid, i))
		if vec.n_used > 0 then
			f(vec)
		end
	end
end

function sim.read1(ref, varid)
	local pv = C.sim_obj_read1(ref, varid)
	local t = ref.vec.bands[varid].type
	return lex.frompvalue_s(pv, t)
end

function sim.write1(ref, varid, value)
	local t = ref.vec.bands[varid].type
	C.sim_obj_write1(ref, varid, lex.topvalue_s(value, t))
end

-------------------------

return {
	create=create_sim
}
