local alloc = require "alloc"
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

return {
	shared_arena = shared_arena
}
