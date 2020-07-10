local ffi = require "ffi"
local cli = require "cli"
local misc = require "misc"
local sim_env = require "sim_env"
local neldermead = require "neldermead"
local log = require("log").logger

local calibrator_mt = { __index={} }

local function calibrator(env, opt)
	local calibrator = setmetatable({
		env        = env,
		parameters = {},
		models     = {}
	}, calibrator_mt)

	env.sim:on("fhk:plan#-1", function(plan)
		local _calibrate = plan.calibrate
		local hook = calibrator:calibrate_hook(plan, opt)
		plan.calibrate = function(name) return hook(name) or _calibrate(name) end
	end)

	return calibrator
end

function calibrator_mt.__index:calibrate_hook(plan, opt)
	return function(name)
		return opt[name] and function(model)
			local def = self:defmodel(name, model)
			for i,pname in ipairs(plan.modeldef[name].coeffs) do
				local o = opt[name][pname] or
					error(string.format("%s#%s: missing optimization settings", name, pname))

				local ptr = model.coefs+(i-1)
				ptr[0] = o.value or error(string.format("%s#%s: missing default value", name, pname))

				if o.optimize then
					def(pname, ptr, o)
				end
			end

			model:calibrate()
		end
	end
end

function calibrator_mt.__index:defmodel(mname, model)
	return function(name, ptr, opt)
		self.models[mname] = self.models[mname] or model
		table.insert(self.parameters, {model=mname, name=name, ptr=ptr, opt=opt})
		log:verbose("%s # %s -> %p -- %f [%f, %f]", mname, name, ptr, opt.value, opt.min, opt.max)
	end
end

function calibrator_mt.__index:penaltyf(k)
	local nparam = #self.parameters
	local min = ffi.new("double[?]", nparam)
	local max = ffi.new("double[?]", nparam)
	k = k or 10000

	for i,p in ipairs(self.parameters) do
		min[i-1] = p.opt.min or -math.huge
		max[i-1] = p.opt.max or math.huge
	end

	return function(xs)
		local p = 0
		for i=0, nparam-1 do
			if xs.data[i] < min[i] or xs.data[i] > max[i] then
				p = p + k
			end
		end
		return p
	end
end

function calibrator_mt.__index:wrap_costf(costf, penaltyf)
	local models = {}
	for _,m in pairs(self.models) do
		table.insert(models, m)
	end

	local nparam = #self.parameters
	local params = ffi.new("double *[?]", nparam)
	for i,p in ipairs(self.parameters) do
		params[i-1] = p.ptr
	end

	if penaltyf == false then
		penaltyf = function() return 0 end
	elseif not penaltyf then
		penaltyf = self:penaltyf()
	end

	return function(xs)
		for i=0, nparam-1 do
			params[i][0] = xs.data[i]
		end

		for i=1, #models do
			models[i]:calibrate()
		end

		return costf() + penaltyf(xs)
	end
end

function calibrator_mt.__index:newpopf(v)
	return function(xs)
		for i,p in ipairs(self.parameters) do
			xs.data[i-1] = v(p.opt)
		end
	end
end

local function linear_param(p)
	return p.min + math.random() * (p.max - p.min)
end

function calibrator_mt.__index:optimizer(config)
	local costf = self:wrap_costf(config.costf, config.penaltyf)
	local optimizer = config.optimizer or
		neldermead.optimizer(costf, #self.parameters, config.optimizer_config or {})
	optimizer:newpop(self:newpopf(config.newparam or linear_param))
	return optimizer
end

function calibrator_mt.__index:dump(xs)
	local solution = {}

	for name,_ in pairs(self.models) do
		solution[name] = {}
	end

	for i,p in ipairs(self.parameters) do
		solution[p.model][p.name] = tonumber(xs.data[i-1])
	end

	return solution
end

function calibrator_mt.__index:optimize(config)
	local optimizer = self:optimizer(config)
	optimizer()
	return self:dump(optimizer.solution)
end

--------------------------------------------------------------------------------

local function main(args)
	local env = sim_env.from_cmdline(args.config)
	local coef =  misc.readjson(args.coef or error("No coefficient file"))
			or error(string.format("%s: failed to read coefficients", args.coef))
	local costf = env:run_file(args.calibrator or error("No calibrator file"))
		or error(string.format("%s: script didn't return a cost function", args.calibrator))

	local calibrator = calibrator(env, coef)
	
	local sim = env.sim
	sim:compile()
	
	if args.input then
		sim:event("calibrate:setup", misc.readjson(args.input))
	end

	local solution = calibrator:optimize {
		costf = costf,
		optimizer_config = { max_iter = tonumber(args.m) or 2000 }
	}

	local encode = require "json.encode"
	print(encode(solution))
end

return {
	cli_main = {
		main = main,
		usage = "calibrator coefs [-c config] [-i input] [-m maxiter]",
		flags = {
			cli.positional("calibrator"),
			cli.positional("coef"),
			cli.opt("-c", "config"),
			cli.opt("-i", "input"),
			cli.opt("-m", "m"),
		}
	},

	calibrator = calibrator
}
