require "alloc"
local conv = require "model.conv"
local ffi = require "ffi"
local C = ffi.C

ffi.metatype("mod_Const", {
	__index = {
		call = C.mod_Const_call
	},
	__gc = C.mod_Const_destroy
})

local function create(sig, values)
	local nr = ffi.new("size_t[?]", #values)
	local rv = ffi.new("void *[?]", #values)

	-- sig.np is allowed to be non-zero, it's not an error if you want to pass parameters
	-- to a constant model (it is pointless though)
	local typ = sig.typ+sig.np

	for i, x in ipairs(values) do
		local isset = conv.isset(typ[i-1])
		local ct = conv.ctypeof(typ[i-1])
		local n = isset and #x or 1
		local p = ffi.cast(ffi.typeof("$*", ct), C.malloc(n * ffi.sizeof(ct)))
		nr[i-1] = n * ffi.sizeof(ct)
		rv[i-1] = p

		if isset then
			for j, v in ipairs(x) do
				p[j-1] = v
			end
		else
			p[0] = x
		end
	end

	local mp = C.mod_Const_create(#values, nr, rv)

	for i=0, #values-1 do
		C.free(rv[i])
	end

	return mp
end

return {
	def = function(...)
		local values = {...}
		return {
			sigmask = conv.sigmask(C.mod_Const_types()),
			create  = function(_, sig) return create(sig, values) end
		}
	end
}
