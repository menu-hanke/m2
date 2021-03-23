local compile = require "fhk.compile"
local graph = require "fhk.graph"
local modcall = require "fhk.modcall"
local reflect = require "lib.reflect"
local ffi = require "ffi"
local C = ffi.C

---- composite ----------------------------------------

local composite_mt = { __index={} }

local function composite(...)
	return setmetatable({...}, composite_mt)
end

local function toview(x, y, ...)
	if not y then
		return x
	else
		return composite(x, y, ...)
	end
end

function composite_mt.__index:add(view)
	table.insert(self, view)
	return self
end

function composite_mt.__index:var(var, ...)
	local ctype, create

	for _,view in ipairs(self) do
		if view.var then
			local t, c = view:var(var, ...)
			if t then
				ctype, create = ctype
					and error(string.format("view not unique: var '%s'", var.name))
					or t, c
			end
		end
	end

	return ctype, create
end

function composite_mt.__index:model(mod, ...)
	local sigmask, create

	for _,view in ipairs(self) do
		if view.model then
			local s, c = view:model(mod, ...)
			if s then
				sigmask, create = sigmask
					and error(string.format("view not unique: model '%s'", mod.name))
					or s, c
			end
		end
	end

	return sigmask, create
end

function composite_mt.__index:edge(mod, var, edge, ...)
	local map, scalar

	for _,view in ipairs(self) do
		if view.edge then
			local m, s = view:edge(mod, var, edge, ...)
			if m then
				map, scalar = map
					and error(string.format("view not unique: edge %s - >%s", mod.name, var.name))
					or m, s
			end
		end
	end

	return map, scalar
end

function composite_mt.__index:shape(...)
	local shapefs = {}

	for _,view in ipairs(self) do
		local f = view.shape and view:shape(...)
		if f then
			table.insert(shapefs, f)
		end
	end

	if #shapefs > 0 then
		return shapefs
	end
end

---- group ----------------------------------------

local group_mt = { __index={} }

local function group(name, ...)
	return setmetatable({
		name = name,
		view = toview(...)
	}, group_mt)
end

function group_mt.__index:var(var)
	if self.view.var and graph.groupof(var.name) == self.name then
		return self.view:var(var, var.name:sub(#self.name+2))
	end
end

function group_mt.__index:model(mod)
	if self.view.model and graph.groupof(mod.name) == self.name then
		return self.view:model(mod, mod.name:sub(#self.name+2))
	end
end

function group_mt.__index:edge(model, var, edge)
	if self.view.edge and graph.groupof(model.name) == self.name then
		return self.view:edge(model, var, edge)
	end
end

function group_mt.__index:shape(name)
	if name == self.name and self.view.shape then
		return self.view:shape()
	end
end

local function fixshape(shape)
	return function() return shape end
end

local scalar_shape = fixshape(1)

---- struct ----------------------------------------

local struct_view_mt = { __index={} }

local function struct_view(ctype, source)
	return setmetatable({
		refct  = reflect.typeof(ctype),
		source = source
	}, struct_view_mt)
end

function struct_view_mt.__index:var(var, name)
	local field = self.refct:member(name or var.name)
	if not field then return end

	return field.type, function(dispatch, idx)
		if type(self.source) == "cdata" then
			return compile.setvalue_constptr(
				dispatch, idx,
				ffi.cast("uintptr_t", ffi.cast("void *", self.source)) + field.offset,
				1,
				var.name
			)
		else
			return compile.setvalue_userfunc_offset(
				dispatch,
				idx,
				self.source,
				field.offset,
				var.name
			)
		end
	end
end

function struct_view_mt.__index:shape(group)
	if type(self.source) == "cdata" and not group then
		return scalar_shape
	end
end

---- array ----------------------------------------

local array_view_mt = { __index={} }

local function array_view(ctype, name, source, size)
	return setmetatable({
		ctype  = ctype,
		refct  = reflect.typeof(ctype),
		name   = name,
		source = source,
		size   = size
	}, array_view_mt)
end

function array_view_mt.__index:var(var, name)
	name = name or var.name
	if name ~= self.name then return end

	return self.refct, function(dispatch, idx)
		if type(self.source) == "cdata" then
			return compile.setvalue_constptr(dispatch, idx, self.source, self.size, var.name)
		else
			return compile.setvalue_array_userfunc(dispatch, idx, self.source, var.name)
		end
	end
end

---- struct-of-arrays ----------------------------------------

local soa_view_mt = { __index={} }

local function soa_view(ctype, source)
	return setmetatable({
		refct  = reflect.typeof(ctype),
		source = source
	}, soa_view_mt)
end

function soa_view_mt.__index:var(var, name)
	name = name or var.name
	local field = self.refct:member(name)
	if not field then return end

	return field.type.element_type, function(dispatch, idx)
		if type(self.source) == "cdata" then
			return compile.setvalue_soa_constptr(dispatch, idx, self.source, name, var.name)
		else
			return compile.setvalue_soa_userfunc(dispatch, idx, self.source, name, var.name)
		end
	end
end

function soa_view_mt.__index:shape(group)
	if group then return end

	if type(self.source) == "cdata" then
		local inst = ffi.cast("struct vec *", self.source)
		return function()
			return inst.n_used
		end
	end
end

---- edges ----------------------------------------

local edge_view_mt = {
	__index = {
		edge = function(self, model, var, edge)
			if self.mapname ~= edge.map then return end
			if self.from and graph.groupof(model.name) ~= self.from then return end
			if self.to == "$" then if graph.groupof(model.name) ~= graph.groupof(var.name) then return end
			elseif self.to then if graph.groupof(var.name) ~= self.to then return end end
			return self.map, self.scalar
		end
	}
}

local builtin_maps = {
	space = { map=C.FHKMAP_SPACE, scalar=false },
	only  = { map=C.FHKMAP_SPACE, scalar=true },
	ident = { map=C.FHKMAP_IDENT, scalar=true }
}

local function edge_view(rule, map, scalar)
	if type(map) == "string" then
		local builtin = builtin_maps[map] or error(string.format("invalid builtin map: '%s'", map))
		map = builtin.map
		if scalar == nil then scalar = builtin.scalar end
	end

	local from, to, name = rule:gsub("%s", ""):match("^([^=]*)=>([^:]*):?(.*)$")

	return setmetatable({
		from    = from ~= "" and from or nil,
		to      = to ~= "" and to or nil,
		mapname = name ~= "" and name or nil,
		map     = map,
		scalar  = scalar
	}, edge_view_mt)
end

local builtin_edge_view = composite(
	edge_view("=>$ :ident", "ident"),
	edge_view("=>  :all", "space"),
	edge_view("=>  :only", "only")
)

---- models ----------------------------------------

local modelset_view_mt = { __index={} }

local function modelset_view(impls)
	return setmetatable({ impls = impls }, modelset_view_mt)
end

local function signature(name, nodeset)
	local signature = modcall.signature()
	local model = nodeset.models[name]

	for i,e in ipairs(model.params) do
		signature.params[i] = {
			scalar = e.scalar,
			ctype  = nodeset.vars[e.target].ctype
		}
	end

	for i,e in ipairs(model.returns) do
		signature.returns[i] = {
			scalar = e.scalar,
			ctype  = nodeset.vars[e.target].ctype
		}
	end

	return signature
end

function modelset_view_mt.__index:model(mod, name)
	name = name or mod.name
	local impl = self.impls[name]
	if not impl then return end

	local nodename = mod.name
	return impl.sigset, function(dispatch, _, nodeset)
		return impl.compile(dispatch, signature(nodename, nodeset))
	end
end

---- auxiliary ----------------------------------------

-- shape views: do nothing but provide a shape function
local size_view_mt = {
	__index = {
		shape = function(self, group)
			if not group then return self.shapef end
		end
	}
}

local function size_view(f)
	return setmetatable({ shapef = f }, size_view_mt)
end

local function fixed_size(size)
	return size_view(fixshape(size))
end

-- translate view: proxies a view with different names, useful for views with name
-- restrictions (ctype views) and generated code
local translate_view_mt = { __index={} }

local function translate_view(translate, ...)
	local tf = type(translate) == "table"
		and function(name) return translate[name] end
		or translate
	
	return setmetatable({
		translate = tf,
		view      = toview(...)
	}, translate_view_mt)
end

function translate_view_mt.__index:var(var, name)
	name = self.translate(name or var.name)
	if name then return self.view:var(var, name) end
end

function translate_view_mt.__index:map_model(mod, name)
	name = self.translate(name or mod.name)
	if name then return self.view:model(mod, name) end
end

function translate_view_mt.__index:shape(...)
	return self.view:shape(...)
end

--------------------------------------------------------------------------------

return {
	composite         = composite,
	group             = group,
	struct_view       = struct_view,
	array_view        = array_view,
	soa_view          = soa_view,
	edge_view         = edge_view,
	builtin_edge_view = builtin_edge_view,
	modelset_view     = modelset_view,
	size_view         = size_view,
	fixed_size        = fixed_size,
	translate_view    = translate_view
}
