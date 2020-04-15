local m2 = require "m2"
local trees = require("sim").trees
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
		local n = #trees
		local ind = m2.vmath.sorti(trees.dbh, n)
		local dcs = assign_dclass(trees.dbh, ind, n)
		local ba_dc = dclass_sum_sim(dcs, trees.ba, n)
		local mba_dc = state.meas_ba_dc
		local f_dc = dclass_sum_sim(dcs, trees.f, n)
		local mf_dc = state.meas_f_dc

		local ret = 0
		--print("-----")
		for i=1, #dclass do
			ret = ret + w_G * math.abs(ba_dc[i] - mba_dc[i])^ex_G
			ret = ret + w_N * math.abs(f_dc[i] - mf_dc[i])^ex_N
			--print(i, ba_dc[i], f_dc[i])
		end

		return (5/state.step) * ret
	end
}

--------------------------------------------------------------------------------

local plots
m2.on("calibrate:setup", function(data)
	plots = data 

	for _,v in ipairs(plots) do
		precalc_dist(v)
	end

	sim:savepoint()
end)

-- don't pregenerate instructions since each instruction generates a new root trace
-- instead just run the time loop here
local function simulate(plot)
	sim:event("sim:setup", plot)

	local t_left = plot.step
	while t_left > 0.01 do
		local step = math.min(t_left, 5)
		sim:event("grow", step)
		t_left = t_left - step
	end

	return costf[use_costf](plot)
end

return function()
	local cost = 0

	for _,v in ipairs(plots) do
		sim:restore()
		sim:enter()
		cost = cost + simulate(v)
		sim:exit()
	end

	return cost
end
