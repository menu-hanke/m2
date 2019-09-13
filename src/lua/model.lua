local ffi = require "ffi"

ffi.metatype("struct model", {
	__call  = function(self, ret, arg) return self.func.call(self, ret, arg) end,
	__gc    = function(self) self.func.destroy(self) end,
	__index = {
		calibrate = function(self) self.func.calibrate(self) end
	}
})

local def_mt = {
	__call     = function(self) return self._create(self._def) end,
	__index    = function(self, k) return self._def[k] end,
	__newindex = function(self, k, v) self._def[k] = v end
}

-- Put the create functions as names rather than references to functions since each implementation
-- is optional, so the symbol may be missing
local impls = {
	R = {
		init = function(def, impl)
			def.fname = impl.file
			def.func = impl.func
			def.mode = ffi.C.MOD_R_EXPAND
		end,
		create = "mod_R_create",
		def = "struct mod_R_def"
	},

	SimoC = {
		init = function(def, impl)
			def.libname = impl.file
			def.func = impl.func
		end,
		create = "mod_SimoC_create",
		def = "struct mod_SimoC_def"
	}
}

local function def(impl)
	local i = impls[impl.lang]

	if not i then
		error(string.format("Unsupported model lang: %s", impl.lang))
	end

	local def = ffi.new(i.def)
	i.init(def, impl)
	return setmetatable({
		_create = ffi.C[i.create],
		_def = def
	}, def_mt)
end

return {
	def   = def,
	error = function() return ffi.string(ffi.C.model_error()) end
}
