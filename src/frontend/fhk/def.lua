local graph = require "fhk.graph"
local model = require "model"
local conv = require "model.conv"
local misc = require "misc"
local ffi = require "ffi"
local C = ffi.C

local defaultkc = {
	k = 1,
	c = 1.5
}

local function getmodel(nodeset, name)
	local mod = nodeset.models[name]
	if not mod then
		mod = graph.model(name)
		nodeset.models[name] = mod
	end

	return mod
end

local function getimpl(impls, name)
	local impl = impls[name]
	if not impl then
		impl = { sigmask=conv.sigmask() }
		impls[name] = impl
	end

	return impl
end

local function touchvar(nodeset, name)
	if not nodeset.vars[name] then
		nodeset.vars[name] = graph.var(name)
	end
end

local function apply_edgef(opt, x, ...)
	if type(x) == "string" then
		misc.merge({target=x}, opt):f(...)
	else
		for i,e in ipairs(x) do
			apply_edgef(x.opt and misc.merge(misc.merge({}, opt), x.opt) or opt, e, ...)
		end
	end
end

local edgef_mt = {
	__call = function(self, ...)
		apply_edgef({}, self, ...)
	end
}

local function toedgef(decl, f)
	return setmetatable({
		decl,
		opt = { f=f }
	}, edgef_mt)
end

local modifier_mt = {
	__mul = function(other, self)
		return setmetatable({ other, opt=self }, edgef_mt)
	end
}

local function modifier(opt)
	return setmetatable(opt, modifier_mt)
end

local function gettarget(edge)
	if type(edge) == "string" then return edge end
	return gettarget(edge[1])
end

local function params(decl)
	return toedgef(decl, function(edge, mod, nodeset, impls)
		table.insert(mod.params, edge)
		touchvar(nodeset, edge.target)
		if edge.tm then
			local impl = getimpl(impls, mod.name)
			impl.sigmask.params[#mod.params] = impl.sigmask.params[#mod.params]:intersect(edge.tm)
		end
	end)
end

local function returns(decl)
	return toedgef(decl, function(edge, mod, nodeset, impls)
		table.insert(mod.returns, edge)
		touchvar(nodeset, edge.target)
		if edge.tm then
			local impl = getimpl(impls, mod.name)
			impl.sigmask.returns[#mod.returns] = impl.sigmask.returns[#mod.returns]:intersect(edge.tm)
		end
	end)
end

local function shadowname(target, guard, arg)
	-- poor man's interning, but at least we get descriptive names as a bonus
	arg = type(arg) == "table" and table.concat(arg, ",") or tostring(arg)
	return string.format("%s %s %s", target, guard, arg)
end

local function check(name)
	return toedgef(name, function(edge, mod, nodeset)
		edge.penalty = edge.penalty or math.huge
		local shadow = shadowname(
			edge.target,
			edge.guard or error(string.format("check edge is missing a guard (%s -> %s)",
				mod.name, edge.target)),
			edge.arg
		)
		edge.var = edge.target
		edge.target = shadow
		touchvar(nodeset, edge.var)

		if not nodeset.shadows[shadow] then
			nodeset.shadows[shadow] = graph.shadow(shadow, edge.var, edge.guard, edge.arg)
		end

		table.insert(mod.shadows, edge)
	end)
end

local function cost(kc)
	return function(mod)
		mod.k = kc.k or mod.k
		mod.c = kc.c or mod.c
	end
end

local function set(map)
	return modifier({map=map})
end

local function as(ty)
	return modifier({tm=conv.typemask(ty)})
end

local function tonumset(set, labels)
	set = type(set) == "table" and set or {set}

	local r = {}

	for _,v in ipairs(set) do
		table.insert(r, (type(v) == "number" and v or labels[v])
			or error(string.format("missing label: %s", v)))
	end

	return r
end

local function tomask(set)
	local mask = 0ULL

	for _,v in ipairs(set) do
		if v < 0 or v > 63 then
			error(string.format("bitset value overflow: %s", v))
		end

		mask = bit.bor(mask, bit.lshift(1ULL, v))
	end

	return mask
end

local function is(mask)
	return modifier({ guard="&", arg=mask })
end

-- try saying it out loud: label table
local labtab_mt = {
	__call = function(self, lab)
		for k,x in pairs(lab) do
			if type(x) == "number" then
				self[k] = x
			elseif type(x) == "table" then
				self(x)
			end
		end
	end
}

local function gdef_env(nodeset, impls)
	local labels = setmetatable({}, labtab_mt)

	local env = setmetatable({

		model = function(name)
			local mod = getmodel(nodeset, name)
			mod.k = mod.k or defaultkc.k
			mod.c = mod.c or defaultkc.c

			-- TODO: if it's a redefinition, only allow changing cost (and impl?), otherwise
			-- error out

			return function(attrs)
				for _,a in ipairs(attrs) do
					a(mod, nodeset, impls)
				end
			end
		end,

		derive = function(x)
			local name = gettarget(x)
			local mod = getmodel(nodeset, name)
			mod.k = 0
			mod.c = 1

			return function(attrs)
				for _,a in ipairs(attrs) do
					a(mod, nodeset, impls)
				end
				if #mod.returns == 0 then
					returns(x)(mod, nodeset, impls)
				end
			end
		end,

		impl = setmetatable({}, {
			__index = function(self, name)
				local def = model.lang(name).def
				self[name] = function(...)
					local args = {...}
					return function(mod, _, impls)
						local oldmask = impls[mod.name] and impls[mod.name].sigmask
						impls[mod.name] = def(unpack(args))
						if not oldmask then return end
						local sm = impls[mod.name].sigmask
						for i=1, #mod.params do
							local tm = rawget(oldmask.params, i)
							if tm then
								sm.params[i] = sm.params[i]:intersect(tm)
							end
						end
						for i=1, #mod.returns do
							local tm = rawget(oldmask.returns, i)
							if tm then
								sm.returns[i] = sm.returns[i]:intersect(tm)
							end
						end
					end
				end
				return self[name]
			end
		}),

		labels  = labels,
		params  = params,
		returns = returns,
		check   = check,
		cost    = cost,
		set     = set,
		as      = as,
		is      = function(set) return is(tomask(tonumset(set, labels))) end,
		is_not  = function(set) return is(bit.bnot(tomask(tonumset(set, labels)))) end,
		ge      = function(x) return modifier({ guard=">=", arg=x }) end,
		gt      = function(x) return modifier({ guard=">", arg=x }) end,
		le      = function(x) return modifier({ guard="<=", arg=x }) end,
		lt      = function(x) return modifier({ guard="<", arg=x }) end

	}, { __index=_G })

	env.read = function(fname) return misc.dofile_env(env, fname) end
	return env
end

local function gdef(nodeset, impls)
	return {
		nodeset = graph.nod
	}
end

local function read(...)
	local def = gdef()
	local env = gdef_env(def)

	for _,f in ipairs({...}) do
		env.read(f)
	end

	return def
end

return {
	env  = gdef_env,
	read = read
}
