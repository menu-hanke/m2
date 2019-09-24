local ffi = require "ffi"

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
			end
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
