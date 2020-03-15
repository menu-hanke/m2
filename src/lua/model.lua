local misc = require "misc"
local alloc = require "alloc"
local ffi = require "ffi"

ffi.metatype("struct model", {
	__call  = function(self, ret, arg) return self.func.call(self, ret, arg) end,
	__gc    = function(self) self.func.destroy(self) end,
	__index = {
		calibrate = function(self) self.func.calibrate(self) end
	}
})

local function mconfigure(self, conf)
	if conf.n_arg and conf.n_arg > 0 then
		self.n_arg = conf.n_arg
		self.atypes = conf.atypes
	end

	if conf.n_ret and conf.n_ret > 0 then
		self.n_ret = conf.n_ret
		self.rtypes = conf.rtypes
	end

	if conf.n_coef and conf.n_coef > 0 then
		self.n_coef = conf.n_coef
	end

	if conf.calibrated then
		self.flags = bit.bor(self.flags, ffi.C.MODEL_CALIBRATED)
	end

	return self
end

local function mparsedef(...)
	local keys = {...}
	-- key1::key2::...::keyN
	local pattern = string.rep("([^:]+)::", #keys-1) .. "(.+)$"
	return function(self, os)
		local vs = {os:match(pattern)}
		for i, k in ipairs(keys) do
			vs[k] = vs[i]
		end
		return self:init(vs)
	end
end

local function checked(f)
	return function(...)
		local ret = f(...)
		if ret == ffi.NULL then
			error(ffi.string(ffi.C.model_error()))
		end
		return ret
	end
end

local function mod(info)
	return function()
		local mt = {
			__call  = type(info.create) == "string" and checked(ffi.C[info.create]) or info.create,
			__index = info.func
		}

		if info.ct then
			return ffi.metatype(info.ct, mt)
		else
			return function() return setmetatable({}, mt) end
		end
	end
end

-- Init these lazily.
-- Support for each language is optional and may not be compiled in, so symbol definitions
-- may be missing and we can't just init them all eagerly.
local impls = setmetatable({}, {__index = misc.lazy {

	Const = mod {
		create = function(self) return ffi.C.mod_Const_create(self.n_ret, self.ret) end,
		func   = {
			init = function(self, opt)
				self.n_ret = #opt.ret
				self.ret = ffi.new("pvalue[?]", #opt.ret)
				for i,v in ipairs(opt.ret) do
					-- these are Lua values and we don't know their (fhk) types until configure,
					-- so just store as float now
					self.ret[i-1].f64 = v
				end
			end,

			configure = function(self, conf)
				assert(conf.n_ret == self.n_ret)
				for i=0, self.n_ret-1 do
					-- now convert to actual type.
					-- the u64 doesn't matter here, but lhs is pvalue and rhs is pvalue
					-- so luajit won't let us just assign it even though they are compatible
					self.ret[i].u64 = ffi.C.vimportd(self.ret[i].f64, conf.rtypes[i]).u64
				end
				return self
			end
		}
	},

	R = mod {
		ct     = "struct mod_R_def",
		create = "mod_R_create",
		func   = {
			init = function(self, opt)
				self.fname = opt.file
				self.func = opt.func
				self.mode = ffi.C.MOD_R_EXPAND
			end,

			parse     = mparsedef("file", "func"),
			configure = mconfigure
		}
	},

	SimoC = mod {
		ct     = "struct mod_SimoC_def",
		create = "mod_SimoC_create",
		func   = {
			init = function(self, opt)
				self.libname = opt.libname
				self.func = opt.func
			end,

			parse     = mparsedef("libname", "func"),
			configure = mconfigure
		}
	},

	Lua = mod {
		ct     = "struct mod_Lua_def",
		create = "mod_Lua_create",
		func   = {
			init = function(self, opt)
				self.module = opt.module
				self.func = opt.func
				self.mode = ffi.C.MOD_LUA_EXPAND
			end,

			parse     = mparsedef("module", "func"),
			configure = mconfigure
		}
	}

}})

--------------------------------------------------------------------------------

local config_mt = { __index={} }

local function config()
	return setmetatable({arena=alloc.arena()}, config_mt)
end

function config_mt.__index:reset()
	self.arena:reset()
	self.n_arg = 0
	self.atypes = nil
	self.n_ret = 0
	self.rtypes = nil
	self.n_coef = 0
	self.calibrated = false
end

function config_mt.__index:newatypes(n)
	self.n_arg = n
	self.atypes = self.arena:new("type", n)
	return self.atypes
end

function config_mt.__index:newrtypes(n)
	self.n_ret = n
	self.rtypes = self.arena:new("type", n)
	return self.rtypes
end

local function def(lang, opt)
	local impl = impls[lang]

	if not impl then
		error(string.format("Unsupported model lang: %s", lang))
	end

	local ret = impl()
	if type(opt) == "string" then
		ret:parse(opt)
	else
		ret:init(opt)
	end
	return ret
end

return {
	def    = def,
	config = config,
	error  = function()
		local err = ffi.C.model_error()
		if err ~= nil then
			return ffi.string(err)
		else
			return "(nil)"
		end
	end
}
