local ffi = require "ffi"
local fhk = require "fhk"
local typing = require "typing"
local C = ffi.C

local virtuals_mt = { __index = {} }
local vset_mt = { __index = {} }

local function virtuals()
	return setmetatable({
		callbacks = {},
	}, virtuals_mt)
end

if C.HAVE_SOLVER_INTERRUPTS == 1 then
	function virtuals_mt.__index:add(func)
		local handle = #self.callbacks + 1
		self.callbacks[handle] = func
		return handle
	end
else
	function virtuals_mt.__index:add()
		error("No interrupt support -- compile with SOLVER_INTERRUPTS=on")
	end
end

function virtuals_mt.__index:vset(vis)
	return setmetatable({
		virtuals = self,
		vis      = vis,
		handles  = {}
	}, vset_mt)
end

local function wrap_interrupt(func, tname)
	return function(ctx, solver)
		local ret = ffi.new("pvalue")
		ret[tname] = func(solver)
		return tonumber(C.gs_resume1(ctx, ret))
	end
end

function vset_mt.__index:define(name, f, tname)
	if self.vis and self.vis.virtualize then
		f = self.vis:virtualize(f)
	end

	self.handles[name] = self.virtuals:add(wrap_interrupt(f, tname))
end

function vset_mt.__index:is_visible(vis, v)
	return (not self.vis) or self.vis:is_visible(vis, v)
end

function vset_mt.__index:is_constant(vis, v)
	return self.vis and self.vis:is_constant(vis, v)
end

function vset_mt.__index:mark_mappings(mark)
	for name,_ in pairs(self.handles) do
		mark(name)
	end
end

function vset_mt.__index:map_var(v, solver)
	return solver.mapper:interrupt(v.name, self.handles[v.name])
end

function vset_mt.__index:create_solver(sf)
	if self.vis then
		return self.vis:create_solver(sf)
	end

	return fhk.create_solver1(sf)
end

return {
	virtuals = virtuals
}
