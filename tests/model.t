-- vim: ft=lua
local models = require("testmod").models
local model = require "model"
local ffi = require "ffi"
local C = ffi.C

local SLOW_TESTS = true

test_parse_sig = function()
	local function ok(s) return tostring(model.parse_sig(s) or nil) == s end
	assert(ok "u8u16u32u64i8i16i32i64>m8m16m32m64fdz")
	assert(ok "U8U16U32U64I8I16I32I64>M8M16M32M64FDZ" )
	assert(ok ">")
	assert(not ok "<")
end

-- TODO: conversion tests

if models.Const then

	test_Const_d              = models.Const(">d", 123)                    :call()        :result(123)
	test_Const_D              = models.Const(">D", {1,2,3})                :call()        :result({1,2,3})
	test_Const_param          = models.Const("u64>u64", 123ULL)            :call(1)       :result(123ULL)

end

if models.Lua then

	test_Lua_ident            = models.Lua("d>d", "models", "id")          :call(1)       :result(1)
	test_Lua_noparam          = models.Lua(">d", "models", "ret1")         :call()        :result(1)
	test_Lua_multiret         = models.Lua("dd>dd", "models", "id")        :call(1, 2)    :result(1, 2)
	test_Lua_set              = models.Lua("D>D", "models", "id")          :call({1,2,3}) :result({1,2,3})
	test_Lua_mixed_multiret   = models.Lua("dD>dD", "models", "id")        :call(1,{2,3}) :result(1,{2,3})

	test_Lua_ret_too_few      = models.Lua("d>dd", "models", "id")         :call(1)       :fails(C.MCALL_INVALID_RETURN)
	test_Lua_ret_set_too_few  = models.Lua("D>D", "models", "id")          :call({1})     :fails(C.MCALL_INVALID_RETURN, 2)
	test_Lua_ret_notset       = models.Lua("d>D", "models", "id")          :call(1)       :fails(C.MCALL_INVALID_RETURN)
	test_Lua_ret_notsingle    = models.Lua("D>d", "models", "id")          :call({1})     :fails(C.MCALL_INVALID_RETURN)
	test_Lua_runtime_error    = models.Lua("", "models", "runtime_error")  :call()        :fails(C.MCALL_RUNTIME_ERROR)
	test_Lua_missing_func     = models.Lua("", "models", "missing")        :call()        :fails(C.MCALL_RUNTIME_ERROR)
	test_Lua_missing_module   = models.Lua("", "models_missing", "func")   :call()        :fails(C.MCALL_RUNTIME_ERROR)
	test_Lua_invalid_syntax   = models.Lua("", "models_syntax", "fail")    :call()        :fails(C.MCALL_RUNTIME_ERROR)

	if SLOW_TESTS then
		-- this must have a lot of iterations (eg. 10k reps isn't enough to blow Lua stack if the
		-- model caller doesn't properly cleanup)
		test_Lua_stress_test      = models.Lua("d>d", "models", "id")      :call(1)       :rep(100000, 1)
		test_Lua_stress_test_set  = models.Lua("D>D", "models", "id")      :call({1})     :rep(100000, {1})
	end

	-- TODO calibrate tests
end
