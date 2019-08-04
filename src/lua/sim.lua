local ffi = require "ffi"
local vmath = require "vmath"

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

local sim = {}
local sim_mt = { __index = sim }
local chaintable_mt = {}

local function create_env_lex(env, lex)
	local id = setmetatable({}, {__index=function(id, name)
		error(string.format("No id matching name '%s'", name))
	end})

	for i=0, vecn(lex.objs)-1 do
		local o = vece(lex.objs, i)
		id[ffi.string(o.name)] = o.id

		for j=0, vecn(o.vars)-1 do
			local v = vece(o.vars, i)
			id[ffi.string(v.name)] = v.id
		end
	end

	for i=0, vecn(lex.envs)-1 do
		local e = vece(lex.envs, i)
		id[ffi.string(e.name)] = e.id
	end

	env.id = id
end

local function create_sim(lex)
	local env = setmetatable({}, {__index=_G})
	create_env_lex(env, lex)
	local chains = setmetatable({}, chaintable_mt)
	local _sim = ffi.gc(ffi.C.sim_create(lex), ffi.C.sim_destroy)

	local sim = setmetatable({
		env=env,
		chains=chains,
		_sim=_sim
	}, sim_mt)

	env.sim = sim
	env.on = delegate(sim, sim.on)

	return sim
end

local function invoke_next_chain(chain, idx, continue, ...)
	if not chain[idx] then
		return continue()
	end

	local res = chain[idx](...)
	-- TODO: if res tells us to branch then do it
	return invoke_next_chain(chain, idx+1, continue, ...)
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
	return invoke_next_chain(self.chains[event], 1, continue, ...)
end

function sim:env_vec(envid)
	local pvec = ffi.new("struct pvec")
	ffi.C.S_env_vec(self._sim, pvec, envid)
	return vmath.vec(pvec)
end

function chaintable_mt:__index(k)
	local ret = create_chain(k)
	self[k] = ret
	return ret
end

-------------------------

return {
	create=create_sim
}
