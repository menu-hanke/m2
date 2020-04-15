local ffi = require "ffi"
local typing = require "typing"
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

function virtuals_mt.__index:vset()
	return setmetatable({
		virtuals = self,
		handles  = {},
		types    = {},
		const    = {}
	}, vset_mt)
end

local function wrap(func, tname)
	return function(solver)
		return ffi.new("pvalue", {[tname]=func(solver)})
	end
end

function vset_mt.__index:virtual(name, f, typ, const)
	typ = typing.pvalues[typ] or typing.tvalues[typ] or typ
	self.handles[name] = self.virtuals:add(wrap(f,
		typ.name or error(string.format("Not a pvalue: %s", typ))))
	self.types[name] = typ
	if const then self.const[name] = true end
end

function vset_mt.__index:fhk_map(name)
	return self.handles[name] and function(solver)
		return C.fhkM_pack_intV(
			self.types[name].desc,
			self.handles[name]
		), self.const[name]
	end
end

return {
	virtuals = virtuals
}
