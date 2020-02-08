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

function vset_mt.__index:is_visible(solver, v)
	return (not self.vis) or (not self.vis.is_visible) or self.vis:is_visible(solver)
end

function vset_mt.__index:is_constant(solver, v)
	return self.vis and self.vis.is_constant and self.vis:is_constant(solver, v)
end

function vset_mt.__index:mark_mappings(_, mark)
	for name,_ in pairs(self.handles) do
		mark(name)
	end
end

function vset_mt.__index:map_var(solver, v)
	return solver.mapper:interrupt(v.name, self.handles[v.name])
end

function vset_mt.__index:create_solver(solver)
	if self.vis and self.vis.create_solver then
		return self.vis:create_solver(solver)
	end

	return solver:create_direct_solver()
end

return {
	virtuals = virtuals
}
