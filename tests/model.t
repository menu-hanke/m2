-- vim: ft=lua
local ffi = require "ffi"
local typing = require "typing"
local model = require "model"

local function have(sym)
	return pcall(function() return ffi.C[sym] end)
end

local ct = {
	r = typing.builtin_types.real64.desc,
	b = typing.builtin_types.bit64.desc,
	u = typing.builtin_types.udata.desc
}

local function settypes(dest, s)
	for i=1, #s do
		dest[i-1] = ct[s:sub(i, i)]
	end
end

local function mtpl(sig)
	local conf = model.config()
	local atpl, rtpl, ncoef, iscal = sig:match("(%w*):(%w*):?(%d*)/?(c?)")
	settypes(conf:newatypes(#atpl), atpl)
	settypes(conf:newrtypes(#rtpl), rtpl)
	conf.n_coef = tonumber(ncoef or 0)
	conf.calibrated = iscal ~= ""

	return function(lang, opt)
		local def = model.def(lang, opt):configure(conf)
		local mod = def()
		local argbuf = ffi.new("pvalue[?]", conf.n_arg)
		local retbuf = ffi.new("pvalue[?]", conf.n_ret)

		return function(...)
			local args = {...}
			for i=0, conf.n_arg-1 do
				argbuf[i] = ffi.C.vimportd(args[i+1], conf.atypes[i])
			end

			local r = mod(retbuf, argbuf)
			if r ~= ffi.C.MODEL_CALL_OK then
				error(string.format("model crashed: %d", r))
			end

			local ret = {}
			for i=0, conf.n_ret-1 do
				ret[i+1] = ffi.C.vexportd(retbuf[i], conf.rtypes[i])
			end

			return unpack(ret)
		end, mod
	end
end

local M_axb      = mtpl "rrr:r"      -- (a, x, b) -> a*x + b
local M_is7      = mtpl "b:b"        -- x -> x == 7 
local M_ret12    = mtpl ":rr"        -- () -> 1,2
local M_axby     = mtpl "rr:r:2"     -- (x, y) -> a*x + b*y     uncalibrated (a=1, b=2)
local M_axby_cal = mtpl "rr:r:2/c"   -- (x, y) -> a*x + b*y     calibrated
local M_crash    = mtpl ":r"         --                         always crashes
local M_ret123   = mtpl ":rrr"       -- () -> 1,2,3             for errors - don't implement

local function cases(lang, mopt)
	return {
		simple = function()
			local axb = M_axb(lang, mopt("axb"))
			assert(axb(1, 2, 3) == 1*2+3)

			local is7 = M_is7(lang, mopt("is7"))
			assert(is7(1) == 0)
			assert(is7(7) == 1)

			local ret12 = M_ret12(lang, mopt("ret12"))
			local a, b = ret12()
			assert(a == 1 and b == 2)
		end,

		errors = function()
			local crash = M_crash(lang, mopt("crash"))
			assert(fails(crash))

			local ret123 = M_ret123(lang, mopt("ret12"))
			assert(fails(ret123))
		end,

		calib = function()
			local axby = M_axby(lang, mopt("axby"))
			assert(axby(1, 2) == 1*1+2*2)

			local axby_cal, axby_cal_m = M_axby_cal(lang, mopt("axby"))
			axby_cal_m.coefs[0] = 100
			axby_cal_m.coefs[1] = 200
			axby_cal_m:calibrate()
			assert(axby_cal(1, 2) == 1*100+2*200)
		end
	}
end

if have("mod_Lua_create") then
	local cases_Lua = cases("Lua", function(name) return string.format("models::%s", name) end)
	test_simple_Lua = cases_Lua.simple
	test_errors_Lua = cases_Lua.errors
	test_calib_Lua = cases_Lua.calib
end

if have("mod_R_create") then
	local cases_R = cases("R", function(name) return string.format("models.r::%s", name) end)
	test_simple_R = cases_R.simple
	test_errors_R = cases_R.errors
	test_calib_R = cases_R.calib
end

-- TODO: simo tests go here

if have("mod_Const_create") then

	function test_Const_1()
		local ret1 = mtpl(":r")("Const", {ret={123}})
		assert(ret1() == 123)
	end

	function test_Const_multi()
		local ret123 = mtpl(":rrr")("Const", {ret={1, 2, 3}})
		local a, b, c = ret123()
		assert(a == 1 and b == 2 and c == 3)
	end

end
