local modcall = require "fhk.modcall"
local compile = require "fhk.compile"
local infer = require "fhk.infer"
local fff = require "fff"
local ffi = require "ffi"

if not fff.has("R") then
	error("m2 is not compiled with R support. compile with -DFFF_R.")
end

local typeset = infer.typeset("double", "int", "bool")
local sigset = modcall.signature(setmetatable({}, { __index = function() return typeset end }))

return {
	loader = function(file, name)
		return {
			sigset = sigset,
			compile = modcall.fff_compiler("R", function(F, signature)
				return ffi.C.fffR_create(F, file, name, fff.signature(signature)),
					string.format("%s:%s", file, name)
			end)
		}
	end
}
