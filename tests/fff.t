-- vim: ft=lua
local tf = require "testfff"
local ffi = require "ffi"
local __ = tf.__
local C = ffi.C

local R = tf.lang "R"
if R then

	test_R_ident = R("models.r", "id", "f64>f64")
		:call(tf.f64(1))
		:result(tf.f64(1))

	test_R_noparam = R("models.r", "ret1", ">f64")
		:call()
		:result(tf.f64(1))

	test_R_scalar_list_multiret = R("models.r", "ret2list", ">f64 f64")
		:call()
		:result(tf.f64(1), tf.f64(2))

	test_R_scalar_vector_multiret = R("models.r", "ret2vec", ">f64 f64")
		:call()
		:result(tf.f64(1), tf.f64(2))

	test_R_single_vector_ret = R("models.r", "ret2vec", ">F64")
		:call()
		:result(tf.f64(1, 2))

	test_R_mixed_multiret = R("models.r", "id2", "f64 F64 > f64 F64")
		:call(tf.f64(1), tf.f64(2,3))
		:result(tf.f64(1), tf.f64(2,3))

	test_R_logical = R("models.r", "not", "z>z")
		:call(tf.z(true))
		:result(tf.z(false))

	test_R_noreturn = R("models.r", "nop", ">f64")
		:call()
		:fails("model didn't return a value", tf.f64(__))

	test_R_NAreturn = R("models.r", "na", ">f64")
		:call()
		:fails("model returned NA", tf.f64(__))

	test_R_NAvec = R("models.r", "navec", ">F64")
		:call()
		:fails("model returned NA", tf.f64(__))

	test_R_wrongtype = R("models.r", "clos", ">z")
		:call()
		:fails(C.FFF_ERR_CRASH, tf.f64(__))

	test_R_retvs_too_few = R("models.r", "id", "f64 > f64 f64")
		:call(tf.f64(1))
		:fails("expected 2 return values, got 1", tf.f64(__), tf.f64(__))

	test_R_retvs_too_many = R("models.r", "id2", "f64 f64 > f64")
		:call(tf.f64(1), tf.f64(2))
		:fails("Wrong number of values", tf.f64(__))

	test_R_retvv_too_few = R("models.r", "id", "F64 > F64")
		:call(tf.f64(1))
		:fails("Wrong number of values", tf.f64(__, __))

	test_R_retvv_too_many = R("models.r", "id", "F64 > F64")
		:call(tf.f64(1,2))
		:fails("Wrong number of values", tf.f64(__))

	test_R_retlv_too_few = R("models.r", "id", "F64 > F64 F64")
		:call(tf.f64(1))
		:fails("expected 2 return values, got 1", tf.f64(__), tf.f64(__))

	test_R_retlv_too_many = R("models.r", "id2", "F64 F64 > F64")
		:call(tf.f64(1), tf.f64(2))
		:fails("Wrong number of values", tf.f64(__))

	test_R_retlv_too_few_e = R("models.r", "id2", "f64 F64 > f64 F64")
		:call(tf.f64(1), tf.f64(2))
		:fails("Wrong number of values", tf.f64(__), tf.f64(__, __))

	test_R_retlv_too_many_e = R("models.r", "id2", "f64 F64 > f64 F64")
		:call(tf.f64(1), tf.f64(2,3))
		:fails("Wrong number of values", tf.f64(__), tf.f64(__))

	test_R_runtime_error = R("models.r", "runtime_error", "")
		:call()
		:fails(C.FFF_ERR_CRASH)

	test_R_missing_func = R("models.r", "missing", "")
		:call()
		:fails(C.FFF_ERR_CRASH)

	test_R_missing_file = R("models_missing.r", "func", "")
		:create_fails(C.FFF_ERR_CRASH)

	test_R_invalid_syntax = R("models_syntax.r", "fail", "")
		:create_fails(C.FFF_ERR_CRASH)
end
