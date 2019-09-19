local ffi = require "ffi"
local conf = require "conf"
local sim_env = require "sim_env"
local nmopt = require "neldermead"

local function readc(cname, cdef)
	if type(cdef) ~= "table" then
		cdef = { value=cdef }
	end

	cdef.name = cname
	
	return cdef
end

local function read_coefs(data)
	local sim_coefs = {}
	local model_coefs = {}

	if data.simulator then
		for cname,cdef in pairs(data.simulator) do
			table.insert(sim_coefs, readc(cname, cdef))
		end
	end

	if data.models then
		for name,coefs in pairs(data.models) do
			model_coefs[name] = {}
			for cname,cdef in pairs(coefs) do
				table.insert(model_coefs[name], readc(cname, cdef))
			end
		end
	end

	return {
		sim   = sim_coefs,
		model = model_coefs
	}
end

local function write_defaults(calib, coefs)
	for modname,coefs in pairs(coefs.model) do
		if not calib[modname] then
			calib[modname] = {}
		end

		local cal = calib[modname]

		for _,c in ipairs(coefs) do
			cal[c.name] = c.value
		end
	end
end

local function collect_cmodels(coefs, mapper)
	local models = {}

	for modname,_ in pairs(coefs.model) do
		-- TODO pick only optimized ones
		table.insert(models, mapper.models[modname].mapping_mod)
	end

	return models
end

local function update_model_coef(self, x)
	--print(self.name, self.ptr[0], "->", x)
	self.ptr[0] = x
end

local function set_updates(coefs, mapper)
	-- TODO sim coefs
	
	for modname,coefs in pairs(coefs.model) do
		local coef_idx = {}
		local mm = mapper.models[modname]
		for idx,cname in ipairs(mm.src.coeffs) do
			coef_idx[cname] = idx
		end
		for _,c in ipairs(coefs) do
			c.ptr = mm.mapping_mod.coefs + (coef_idx[c.name]-1)
			c.update = update_model_coef
		end
	end
end

local function collect_coefs(coefs)
	local ret = {}
	-- TODO sim coefs
	
	for _,cs in pairs(coefs.model) do
		for _,c in ipairs(cs) do
			if c.optimize then
				table.insert(ret, c)
			end
		end
	end

	return ret
end

local function recalibrate(coefs, cmodels, x)
	for i,c in ipairs(coefs) do
		c:update(x.data[i-1])
	end

	for _,m in ipairs(cmodels) do
		m:calibrate()
	end

	-- TODO calibrate sim coefs
end

local function penalty(cs, x)
	-- XXX
	local ret = 0
	for i,c in ipairs(cs) do
		local v = x.data[i-1]
		if v < c.min or v > c.max then
			ret = ret + 10000
		end
	end
	return ret
end

local function randpop(coefs, x)
	for i,c in ipairs(coefs) do
		x.data[i-1] = c.min + math.random() * (c.max - c.min)
	end
end

local function solved(coefs, x)
	for i,c in ipairs(coefs) do
		c.solution = tonumber(x.data[i-1])
	end
end

local function write_solution(coefs)
	-- TODO sim
	
	local cal = {}

	for name,cs in pairs(coefs.model) do
		cal[name] = {}
		for _,c in ipairs(cs) do
			--print(c.name, c.value, c.solution)
			cal[name][c.name] = c.solution
		end
	end

	local encode = require "json.encode"
	print(encode(cal))
end


local function main(args)
	if not args.scripts then error("No scripts given, give some with -s") end
	if not args.coefs then error("No coefficient file, give with -p") end
	if not args.calibrator then error("No calibrator script, give with -C") end

	math.randomseed(os.time())

	local coefs = read_coefs(readjson(args.coefs))
	local cfg = conf.read(args.config)
	write_defaults(cfg.calib, coefs)
	local env = sim_env.from_conf(cfg)

	set_updates(coefs, env.mapper)
	local cs = collect_coefs(coefs)
	local cmodels = collect_cmodels(coefs, env.mapper)

	for _,s in ipairs(args.scripts) do
		env:run_file(s)
	end

	env:inject("args", args)
	-- XXX: this is a bit ugly but it's needed so the cost function can call setup
	-- there's probably a better way to achieve this
	env:inject("env", env)
	local costf = env:run_file(args.calibrator)

	env:prepare()
	env.sim:savepoint()

	local F = function(x)
		recalibrate(cs, cmodels, x)
		return costf() + penalty(cs, x)
	end

	local optimize = nmopt.optimizer(F, #cs, {max_iter=100})
	optimize:newpop(function(x) randpop(cs, x) end)
	optimize()

	solved(cs, optimize.solution)
	write_solution(coefs)
end

return { main=main }
