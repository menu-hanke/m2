local m2 = require "m2"
local sim = m2.sim

local dclass = {
	[0] = -math.huge,
	3.1,6.1,9.1,12.1,15.1,18.1,21.1,24.1,27.1,30.1,
	33.1,36.1,39.1,42.1,45.1,48.1,51.1,54.5,57.5,99.9
}

local w_G = 1.0
local w_N = 0.001
local ex_G = 1.2
local ex_N = 1.2
local use_costf = 2

--------------------------------------------------------------------------------

local function newdist()
	local ret = {}
	for i,_ in ipairs(dclass) do
		ret[i] = 0
	end
	return ret
end

local function dclass_sum_data(trees, field)
	local ret = newdist()
	for _,t in ipairs(trees) do
		for i=#dclass, 1, -1 do
			if t.dbh >= dclass[i] then
				break
			end
			ret[i] = ret[i] + t[field]
		end
	end
	return ret
end

local function cdiff(x)
	local ret = { x[1] }
	for i=2, #x do
		ret[i] = x[i] - x[i-1]
	end
	return ret
end

local function precalc_dist(state)
	state.meas_ba_dc_cumul = dclass_sum_data(state.trees_after, "ba")
	state.meas_f_dc_cumul = dclass_sum_data(state.trees_after, "f")
	state.meas_ba_dc = cdiff(state.meas_ba_dc_cumul)
	state.meas_f_dc = cdiff(state.meas_f_dc_cumul)
end

local function assign_dclass(dbh, ind, n)
	local ret = {}
	local dc = #dclass
	local dv = dclass[dc]

	for i=0, n-1 do
		local d = dbh[ind[i]]
		while d <= dv do
			dc = dc-1
			dv = dclass[dc]
		end

		ret[ind[i]] = dc+1
	end

	return ret
end

local function dclass_sum_sim(dcs, band, n)
	local ret = newdist()
	for i=0, n-1 do
		local j = dcs[i]
		ret[j] = ret[j] + band[i]
	end
	return ret
end

local function psum(x)
	local ret = { x[1] }
	for i=2, #x do
		ret[i] = x[i] + ret[i-1]
	end
	return ret
end

local costf = {
	[2] = function(state)
		local n = trees:len()
		local dbh = trees:bandv("dbh")
		local ind = dbh:sorti()
		local dcs = assign_dclass(dbh.data, ind, n)

		local ba = trees:band("ba")
		local f = trees:band("f")
		local ba_dc = dclass_sum_sim(dcs, ba, n)
		local mba_dc = state.meas_ba_dc
		local f_dc = dclass_sum_sim(dcs, f, n)
		local mf_dc = state.meas_f_dc

		local ret = 0
		for i=1, #dclass do
			ret = ret + w_G * math.abs(ba_dc[i] - mba_dc[i])^ex_G
			ret = ret + w_N * math.abs(f_dc[i] - mf_dc[i])^ex_N
		end

		return (5/state.step) * ret
	end
}

m2.on("measure", function(state)
	state.cost = costf[use_costf](state)
end)

local decode = require "json.decode"
local infile = io.open(m2.calibrate.args.input)
local data = decode(infile:read("*a"))
infile:close()

m2.on("sim:compile", function()
	for i,v in ipairs(data) do
		v.index = i
		precalc_dist(v)

		local instr = m2.record()
		local t_left = v.step
		while t_left > 0 do
			local step = math.min(t_left, 5)
			instr.grow(step)
			t_left = t_left - step
		end
		instr.measure(v)
		v.instr = sim:compile_instr(instr)
	end
end)

return function()
	for i,v in ipairs(data) do
		sim:restore()
		sim:enter()
		sim:event("sim:setup", v) -- XXX
		sim:simulate(v.instr)
		sim:exit()
	end

	local ret = 0
	for i,v in ipairs(data) do
		ret = ret + v.cost
	end

	--print("cost: ", ret)

	return ret
end
