local alloc = require "alloc"
local model = require "model"
local ffi = require "ffi"
local C = ffi.C

local function rdef(sig, ...)
	local rd = {...}

	if #rd == 0 then
		for i=sig.np, sig.np+sig.nr-1 do
			table.insert(rd, 1)
		end
	end

	return rd
end

local mcall_mt = {
	__index = {
		fails = function(self, ...)
			local rd = rdef(self._sig, ...)
			return function()
				assert(not self(rd))
			end
		end,

		_eq = function(self, result)
			local resdef = {}
			for i, r in ipairs(result) do
				resdef[i] = type(r) == "table" and #r or 1
			end

			local ok, rv = self(resdef)

			if not ok then
				error(string.format("Model call failed:\n%s", ffi.string(C.model_error())))
			end

			for i, r in ipairs(result) do
				if type(r) == "table" then
					for j, v in ipairs(r) do
						if rv[i][j] ~= v then
							error(string.format("Expected return value #%d[%d] = %f, but got %f",
								i, j, v, rv[i][j]))
						end
					end
				else
					if rv[i] ~= r then
						error(string.format("Expected return value #%d = %f, but got %f",
							i, r, rv[i]))
					end
				end
			end

			return true
		end,

		result = function(self, ...)
			local result = {...}
			return function()
				assert(self:_eq(result))
			end
		end,

		rep = function(self, n, ...)
			local result = {...}
			return function()
				-- TODO: this is lazy because it keeps repacking the parameters and
				-- reallocating the mcall_s, it should just allocate it once and reuse it.
				-- (but perf doesn't really matter much here)
				-- (and the api would probably look cleaner if this returned a new mcall,
				-- like model.X(...):call(...):repeat(...):result(...))
				for i=1, n do
					assert(self:_eq(result))
				end
			end
		end
	},

	__call = function(self, resdef)
		local e = {}
		for _,a in ipairs(self._args) do table.insert(e, a) end
		for _,r in ipairs(resdef) do table.insert(e, r) end
		local arena = alloc.arena()
		local mcs = model.prepare_call(arena, self._sig, e)
		return model.call(self._mp, mcs, self._sig)
	end
}

local def_proxy = {
	__index = {
		call = function(self, ...)
			local mp = self._def:create(self._sig)

			return setmetatable({
				_mp   = mp,
				_sig  = self._sig,
				_args = {...}
			}, mcall_mt)
		end,

		create_fails = function(self)
			return function()
				assert(not pcall(function() return self._def:create(self._sig) end))
			end
		end
	}
}

local mod_proxy = setmetatable({}, {
	__index = function(self, name)
		local module = model.lang(name)
		self[name] = (module.def ~= nil) and function(s, ...)
			local sig = model.parse_sig(s)
			return setmetatable({
				_sig = sig,
				_def = module.def(...)
			}, def_proxy)
		end
		return self[name]
	end
})

return {
	models = mod_proxy
}
