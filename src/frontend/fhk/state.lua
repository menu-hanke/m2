local compile = require "fhk.compile"
local alloc = require "alloc"
local memoize = require "memoize"
local ffi = require "ffi"
local C = ffi.C

local function shared_arena()
	local arena = alloc.arena(2^20)
	local refcount = 0

	local function obtain()
		refcount = refcount + 1
		return arena
	end

	local function release()
		refcount = refcount - 1
		if refcount == 0 then
			arena:reset()
		end
	end

	return obtain, release
end

local function frame_arena(sim)
	local arena = alloc.arena_nogc(2^20)
	local ap = ffi.gc(sim:new(ffi.typeof"arena *", "vstack"), function() arena:destroy() end)
	ap[0] = arena

	local _obtain = memoize.memoize(sim, function()
		local a = sim:alloc(ffi.sizeof("arena"), ffi.alignof("arena"), "frame")
		ffi.copy(a, ap[0], ffi.sizeof("arena"))
		ap[0] = a
		return ap[0]
	end, 1, 1)

	local function obtain()
		return _obtain(sim:fp())
	end

	return obtain, function() end
end

-- TODO: a better way to implement this could be to just use frame memory,
-- (that needs some changes in the solver to allow a generic allocator function)
-- note: this will only work for a single view, as the arena is cloned.
-- the same principle will work for multiple views, but the (cloned) arena must be
-- memoized separately so that it's only cloned once per frame.
local function incremental(sim, G, shapef, key)
	local obtain, release = frame_arena(sim)
	local _push = memoize.memoize(sim, compile.pushstate_uncached(G, shapef, obtain), 3, 3)

	local function push(A)
		return _push(A, key(), sim:fp())
	end

	return push, release
end

return {
	shared_arena = shared_arena,
	incremental  = incremental
}
