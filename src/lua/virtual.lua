local ffi = require "ffi"
local C = ffi.C

local virtuals_mt = { __index = {} }
local vset_mt = { __index = {} }

local function virtuals()
	return setmetatable({
		callbacks = {},
	}, virtuals_mt)
end

function virtuals_mt.__index:add(func)
	local handle = #self.callbacks + 1
	self.callbacks[handle] = func
	return handle
end

function virtuals_mt.__index:vset(vis)
	return setmetatable({
		virtuals = self,
		vis      = vis,
		handles  = {}
	}, vset_mt)
end

local function wrap_interrupt(func, tname)
	return function(solver, u)
		local r = func(u)
		local iv = ffi.new("pvalue")
		iv[tname] = r
		return tonumber(C.fhkG_solver_resumeV(solver, iv))
	end
end

function vset_mt.__index:define(name, f, tname)
	self.handles[name] = self.virtuals:add(wrap_interrupt(f, tname))
end

function vset_mt.__index:define_mappings(def, map)
	local const = def.udata[self].const

	for name,handle in pairs(self.handles) do
		map(name, function(desc)
			local mapping = def.arena:new("struct fhkG_vintV")
			mapping.flags.resolve = C.FHKG_MAP_INTERRUPT
			mapping.flags.type = desc
			mapping.flags.handle = handle
			return mapping, const
		end)
	end
end

return {
	virtuals = virtuals
}
