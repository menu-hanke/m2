local compile = require "fhk.compile"
local graph = require "fhk.graph"
local driver = require "fhk.driver"
local conv = require "model.conv"
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

local function struct_view(ctype, inst)
	return setmetatable({
		refct = reflect.typeof(ctype),
		inst  = inst
	}, struct_view_mt)
end

function struct_view_mt.__index:ref_umem(umem)
	if not umem[self] then
		local inst = self.inst
		umem[self] = umem:scalar(ffi.typeof("void *"), function(state)
			return state[inst]       ---> ctype *
		end)
	end

	return umem[self]
end

function struct_view_mt.__index:var(var, name)
	local field = self.refct:member(name or var.name)
	if not field then return end

	local create
	if type(self.inst) == "cdata" then
		local ptr = ffi.cast("uint8_t *", self.inst) + field.offset
		create = function(dv)
			dv:set_vrefk(ptr)  ---> ptr
		end
	else
		local offset = field.offset
		create = function(dv, umem)
			local field = self:ref_umem(umem)
			umem:on_ctype(function(ctype)
				dv:set_vrefu(ffi.offsetof(ctype, field), offset)   ---> *udata + offset
			end)
		end
	end

	return field.type, create
end

function struct_view_mt.__index:shape(group)
	if not group then
		return scalar_shape
	end
end

---- array ----------------------------------------

local array_view_mt = { __index={} }

local function array_view(objs)
	return setmetatable({objs = objs}, array_view_mt)
end

function array_view_mt.__index:ref_umem(umem, name)
	-- this could technically be called multiple times if multiple variables resolve
	-- to the same name (think aliases etc.)

	if not umem[self] then
		umem[self] = {}
	end

	if not umem[self][name] then
		umem[self][name] = umem:scalar(ffi.typeof("void *", function(state)
			return state[name]    ---> obj *
		end))
	end

	return gen[self][name]
end

function array_view_mt.__index:var(var, name)
	name = name or var.name
	local obj = self.objs[name]
	if not obj then return end

	local ct = ffi.typeof(obj)
	local refct = reflect.typeof(ct)
	local create

	if type(obj) ~= "cdata" or obj == ct then -- it's a type
		create = function(dv, umem)
			local field = self:ref_umem(umem, name)
			umem:on_ctype(function(ctype)
				dv:set_vrefu(ffi.offset(ctype, field))     ---> udata
			end)
		end
	else -- it's cdata
		refct = refct.element_type
		create = function(dv)
			dv:set_vrefk(ffi.cast("void *", obj))       ---> obj
		end
	end

	return refct, create
end

---- struct-of-arrays ----------------------------------------

local soa_view_mt = { __index={} }

local function soa_view(ctype, inst)
	return setmetatable({
		refct = reflect.typeof(ctype),
		inst  = inst
	}, soa_view_mt)
end

function soa_view_mt.__index:ref_umem(umem)
	if not umem[self] then
		local inst = self.inst
		umem[self] = umem:scalar(ffi.typeof("void *"), function(state)
			return state[inst]   ---> struct vec *
		end)
	end

	return umem[self]
end

function soa_view_mt.__index:var(var, name)
	local field = self.refct:member(name or var.name)
	if not field then return end

	local create
	if type(self.inst) == "cdata" then
		local ptr = ffi.cast("uint8_t *", self.inst) + field.offset  ---> &inst->band
		create = function(dv)
			dv:set_vrefk(ptr, 0)     ---> *ptr
		end
	else
		local offset = field.offset
		create = function(dv, umem)
			local field = self:ref_umem(umem)
			umem:on_ctype(function(ctype)
				dv:set_vrefu(ffi.offsetof(ctype, field), offset, 0) ---> *(*udata + offset)
			end)
		end
	end

	return field.type.element_type, create
end

local soa_ctp = ffi.typeof("struct vec *")
function soa_view_mt.__index:shape(group)
	if group then return end

	if type(self.inst) == "cdata" then
		local inst = ffi.cast(soa_ctp, self.inst)
		return function()
			return inst.n_used
		end
	else
		local inst = self.inst
		return function(state)
			return ffi.cast(soa_ctp, state[inst]).n_used
		end
	end
end

---- edges ----------------------------------------

local match_edges_mt = {
	__index = {
		edge = function(rules, model, var, edge)
			if edge.map then return end
			for _,f in ipairs(rules) do
				local map, scalar = f(model, var, edge)
				if map then return map, scalar end
			end
		end
	}
}

local function match_edges(rules)
	local rt = {}

	for i,rule in ipairs(rules) do
		local r,f = rule[1], rule[2]
		local from, to = r:match("^(.-)=>(.-)$")
		from = from == "" and "^(.*)$" or ("^" .. from .. "$")
		to = to == "" and "^(.*)$" or ("^" .. to .. "$")

		rt[i] = function(model, var, edge)
			local mg = {graph.groupof(model.name):match(from)}
			if #mg == 0 then return end

			if not graph.groupof(var.name):match(to:gsub("(%%%d+)",
				function(j) return mg[tonumber(j:sub(2))] end)) then
				return
			end

			return f(model, var, edge)
		end
	end

	return setmetatable(rt, match_edges_mt)
end

local function space() return C.FHKM_SPACE, false end
local function only() return C.FHKM_SPACE, true end
local function ident() return C.FHKM_IDENT, true end

local builtin_maps = {
	all   = space,
	only  = only,
	ident = ident
}

local builtin_edge_view = {
	edge = function(_, _, _, edge)
		if edge.map and builtin_maps[edge.map] then
			return builtin_maps[edge.map]()
		end
	end
}

---- models ----------------------------------------

local modelset_view_mt = { __index={} }

local function modelset_view(impls, alloc)
	return setmetatable({
		impls = impls,
		alloc = alloc
	}, modelset_view_mt)
end

local function signature(name, nodeset)
	-- TODO don't hardcode the size
	local node = nodeset.models[name]
	local sigg = ffi.gc(ffi.cast("struct mt_sig *", C.malloc(514)), C.free)
	local sigm = ffi.gc(ffi.cast("struct mt_sig *", C.malloc(514)), C.free)
	sigg.np = #node.params
	sigm.np = #node.params
	sigg.nr = #node.returns
	sigm.nr = #node.returns

	local i = 0
	for _,es in ipairs({node.params, node.returns}) do
		for _,e in ipairs(es) do
			local ty = conv.fromctype(nodeset.vars[e.target].ctype)
			if not e.scalar then ty = conv.toset(ty) end
			sigg.typ[i] = ty
			sigm.typ[i] = C.mt_autoconv(ty, e.tm.mask)

			if sigm.typ[i] == C.MT_INVALID then
				error(string.format("can't autoconvert signature: %s -> %s (parameter '%s' of '%s')",
					conv.nameof(ty), e.tm, e.target, name))
			end

			i = i+1
		end
	end

	return sigg, sigm
end

function modelset_view_mt.__index:model(mod, name)
	-- TODO cache these

	name = name or mod.name
	local impl = self.impls[name]
	if not impl then return end

	local nodename = mod.name
	return impl.sigmask, function(dm, _, nodeset)
		local sigg, sigm = signature(nodename, nodeset)
		local m = impl:create(sigm)
		dm:set_mcall(m.call, m, driver.conv(sigg, sigm, self.alloc))
	end
end

---- auxiliary ----------------------------------------

-- fixed view: does nothing but provides a shape
local fixed_view_mt = {
	__index = {
		shape = function(self, group)
			if not group then return self.shapef end
		end
	}
}

local function fixed_size(size)
	return setmetatable({
		shapef = fixshape(size)
	}, fixed_view_mt)
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
	match_edges       = match_edges,
	builtin_maps      = builtin_maps,
	builtin_edge_view = builtin_edge_view,
	space             = space,
	only              = only,
	ident             = ident,
	modelset_view     = modelset_view,
	fixed_size        = fixed_size,
	translate_view    = translate_view
}
