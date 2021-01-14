-- vim: ft=lua
local models = require("testmod").models
local model = require "model"
local conv = require "model.conv"
local ffi = require "ffi"
local C = ffi.C

local SLOW_TESTS = os.getenv("M2_SLOW_TESTS") == "on"

test_parse_sig = function()
	local function ok(s) return tostring(model.parse_sig(s)) == s end
	assert(ok "u8u16u32u64i8i16i32i64>fdz")
	assert(ok "U8U16U32U64I8I16I32I64>FDZ" )
	assert(ok ">")
	assert(fails(function() model.parse_sig "<" end))
end

test_cconv = function()
	local types = {
		C.MT_SINT8, C.MT_SINT16, C.MT_SINT32, C.MT_SINT64,
		C.MT_UINT8, C.MT_UINT16, C.MT_UINT32, C.MT_UINT64,
		C.MT_FLOAT, C.MT_DOUBLE,
		C.MT_BOOL
		-- ignore C.MT_POINTER, it can't be converted
	}

	local tests = {
		-- this must have the cast explicitly or else luajit does the conversion through double
		-- and then the conversion to (u)int64_t will not work
		{ C.MT_SINT8, {ffi.cast("int8_t", -1)} },

		{ C.MT_UINT8, {1} },
		{ C.MT_UINT16,  {256} },

		-- cast to float or they will be doubles
		{ C.MT_FLOAT, {ffi.cast("float", 0), ffi.cast("float", 1.23), ffi.cast("float", 1.99)} },

		{ C.MT_DOUBLE, {-0.5} },
		-- { C.MT_DOUBLE, {-2^40} }, -- this is UB,
		{ C.MT_BOOL, {true, false} }
	}

	for _,test in ipairs(tests) do
		local sty, vals = test[1], test[2]
		local val_buf = ffi.new(ffi.typeof("$[?]", conv.ctypeof(sty)), #vals, vals)

		for _,dty in ipairs(types) do
			local test_buf = ffi.new(ffi.typeof("$[?]", conv.ctypeof(dty)), #vals)
			local res = C.mt_cconv(test_buf, dty, val_buf, sty, #vals)

			if res ~= 0 then
				error(string.format("mt_cconv() failed on %s -> %s",
					conv.nameof(sty), conv.nameof(dty)))
			end

			-- workaround because ffi.cast doesn't (obviously) convert to a lua type
			local expect = ffi.new(ffi.typeof("$[?]", conv.ctypeof(dty)), #vals, vals)
			for i=0, #vals-1 do
				if test_buf[i] ~= expect[i] then
					error(string.format("invalid conversion %s [%s] -> %s [%s] -- should have been %s",
						conv.nameof(sty), tonumber(vals[i+1]), conv.nameof(dty), test_buf[i], expect[i]))
				end
			end
		end
	end
end

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

	test_Lua_ret_too_few      = models.Lua("d>dd", "models", "id")         :call(1)       :fails()
	test_Lua_ret_set_too_few  = models.Lua("D>D", "models", "id")          :call({1})     :fails(2)
	test_Lua_ret_notset       = models.Lua("d>D", "models", "id")          :call(1)       :fails()
	test_Lua_ret_notsingle    = models.Lua("D>d", "models", "id")          :call({1})     :fails()
	test_Lua_runtime_error    = models.Lua("", "models", "runtime_error")  :call()        :fails()
	test_Lua_missing_func     = models.Lua("", "models", "missing")        :call()        :fails()
	test_Lua_missing_module   = models.Lua("", "models_missing", "func")   :call()        :fails()
	test_Lua_invalid_syntax   = models.Lua("", "models_syntax", "fail")    :call()        :fails()

	test_Lua_bytecode         = models.LuaJIT("d>d", function(x) return x+1 end)
	                                                                       :call(1)       :result(2)

	if SLOW_TESTS then
		-- this must have a lot of iterations (eg. 10k reps isn't enough to blow Lua stack if the
		-- model caller doesn't properly cleanup)
		test_Lua_stress_test      = models.Lua("d>d", "models", "id")      :call(1)       :rep(100000, 1)
		test_Lua_stress_test_set  = models.Lua("D>D", "models", "id")      :call({1})     :rep(100000, {1})
	end

	-- TODO calibrate tests
end

if models.R then

	test_R_ident              = models.R("d>d", "models.r", "id")          :call(1)       :result(1)
	test_R_noparam            = models.R(">d", "models.r", "ret1")         :call()        :result(1)
	test_R_scalar_list_multiret = models.R(">dd", "models.r", "ret2list")  :call()        :result(1, 2)
	test_R_scalar_vector_multiret = models.R(">dd", "models.r", "ret2vec") :call()        :result(1, 2)
	test_R_single_vector_ret  = models.R(">D", "models.r", "ret2vec")      :call()        :result({1, 2})
	test_R_mixed_multiret     = models.R("dD>dD", "models.r", "id2")       :call(1,{2,3}) :result(1,{2,3})
	test_R_logical            = models.R("z>z", "models.r", "not")         :call(true)    :result(false)

	test_R_noreturn           = models.R(">d", "models.r", "nop")          :call()        :fails()
	test_R_NAreturn           = models.R(">d", "models.r", "na")           :call()        :fails()
	test_R_NAvec              = models.R(">D", "models.r", "navec")        :call()        :fails()
	test_R_wrongtype          = models.R(">z", "models.r", "clos")         :call()        :fails()
	test_R_retvs_too_few      = models.R("d>dd", "models.r", "id")         :call(1)       :fails()
	test_R_retvs_too_many     = models.R("dd>d", "models.r", "id2")        :call(1,2)     :fails()
	test_R_retvv_too_few      = models.R("D>D", "models.r", "id")          :call({1})     :fails(2)
	test_R_retvv_too_many     = models.R("D>D", "models.r", "id")          :call({1,2})   :fails()
	test_R_retlv_too_few      = models.R("D>DD", "models.r", "id")         :call({1})     :fails()
	test_R_retlv_too_many     = models.R("DD>D", "models.r", "id2")        :call({1},{2}) :fails()
	test_R_retlv_too_few_e    = models.R("dD>dD", "models.r", "id2")       :call(1,{2})   :fails(1, 2)
	test_R_retlv_too_many_e   = models.R("dD>dD", "models.r", "id2")       :call(1,{2,3}) :fails()
	test_R_runtime_error      = models.R("", "models.r", "runtime_error")  :call()        :fails()
	test_R_missing_func       = models.R("", "models.r", "missing")        :call()        :fails()
	test_R_missing_file       = models.R("", "models_missing.r", "func")   :create_fails()
	test_R_invalid_syntax     = models.R("", "models_syntax.r", "fail")    :create_fails()

end
