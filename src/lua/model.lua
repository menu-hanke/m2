local ffi = require "ffi"
local alloc = require "alloc"

ffi.metatype("struct model", {
	__call  = function(self, ret, arg) return self.func.call(self, ret, arg) end,
	__gc    = function(self) self.func.destroy(self) end,
	__index = {
		calibrate = function(self) self.func.calibrate(self) end
	}
})

local function init_defbase(def)
	def.n_arg = 0
	def.n_ret = 0
	def.flags = 0
end

local def_func = { __index = {
	args = function(self, atypes, n_arg)
		self.atypes = atypes
		self.n_arg = n_arg
	end,

	rets = function(self, rtypes, n_ret)
		self.rtypes = rtypes
		self.n_ret = n_ret
	end,

	coefs = function(self, n_coef)
		self.n_coef = n_coef
	end,

	calibrated = function(self)
		self.flags = bit.bor(self.flags, ffi.C.MODEL_CALIBRATED)
		return self
	end
}}

local function mod(info)
	return function()
		ffi.metatype(info.def, {
			__call  = ffi.C[info.create],
			__index = info.func
		})

		return info.def
	end
end

-- Init these lazily.
-- Support for each language is optional and may not be compiled in, so symbol definitions
-- may be missing and we can't just init them all eagerly.
local impls = setmetatable({}, {__index = lazy {

	Const = function()
		return ffi.metatype("struct { unsigned n_ret; pvalue *ret; }", {
			__call = function(self)
				return ffi.C.mod_Const_create(self.n_ret, self.ret)
			end,

			__gc = function(self)
				ffi.C.free(self.ret)
			end,

			__index = {
				init = function(self, impl)
					self.n_ret = #impl.ret
					self.ret = alloc.malloc_nogc("pvalue", #impl.ret)
					for i,v in ipairs(impl.ret) do
						self.ret[i-1].f64 = v
					end
				end,

				rets = function(self, rtypes)
					for i=0, tonumber(self.n_ret)-1 do
						-- the u64 doesn't matter here, but lhs is pvalue and rhs is pvalue
						-- so luajit won't let us just assign it even though they are compatible
						self.ret[i].u64 = ffi.C.vimportd(self.ret[i].f64, rtypes[i]).u64
					end
				end,

				args = function() end,
				coefs = function() end,
			}
		})
	end,

	R = mod {
		create = "mod_R_create",
		def    = "struct mod_R_def",
		func   = setmetatable({
			init = function(self, impl)
				init_defbase(self)
				self.fname = impl.file
				self.func = impl.func
				self.mode = ffi.C.MOD_R_EXPAND
			end
		}, def_func)
	},

	SimoC = mod {
		create = "mod_SimoC_create",
		def    = "struct mod_SimoC_def",
		func   = setmetatable({
			init = function(self, impl)
				init_defbase(self)
				self.libname = impl.file
				self.func = impl.func
			end,
			coefs = function() end
		}, def_func)
	},

	Lua = mod {
		create = "mod_Lua_create",
		def    = "struct mod_Lua_def",
		func   = setmetatable({
			init = function(self, impl)
				init_defbase(self)
				self.module = impl.file
				self.func = impl.func
				self.mode = ffi.C.MOD_LUA_EXPAND
			end
		}, def_func)
	}

}})

local function def(impl)
	local i = impls[impl.lang]

	if not i then
		error(string.format("Unsupported model lang: %s", impl.lang))
	end

	local ret = ffi.new(i)
	ret:init(impl)
	return ret
end

return {
	def   = def,
	error = function() return ffi.string(ffi.C.model_error()) end
}
