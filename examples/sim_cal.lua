local Plot = obj("Plot", types.plot)
local Tree = obj("Tree", types.tree)
Plot:hint("trees", Tree:refvec())
fhk.expose(Plot)
fhk.expose(Tree)

local plots = Plot:vec()

local function update_ba(trees)
	local f = trees:band("f")
	local d = trees:bandv("dbh")
	local ba = trees:newbandv("ba")
	d:area(ba.data)
	ba:mul(f)
	ba:mul(1/10000.0) -- XXX: skaalaus että yksiköt menee oikein
	trees:swap("ba", ba.data)
end

local function update_baL(trees)
	local ba = trees:bandv("ba")
	local ba_L = trees:newband("ba_L")
	local ba_Lma = trees:newband("ba_Lma")
	local ba_Lku = trees:newband("ba_Lku")
	local ba_Lko = trees:newband("ba_Lko")
	local ind = ba:sorti()
	local spe = trees:bandv("spe"):vmask()

	ba:psumi(ba_L, ind)
	ba:mask(spe, enum.species.manty):psumi(ba_Lma, ind)
	ba:mask(spe, enum.species.kuusi):psumi(ba_Lku, ind)
	ba:mask(spe, bit.bnot(enum.species.manty + enum.species.kuusi)):psumi(ba_Lko, ind)

	trees:swap("ba_L", ba_L)
	trees:swap("ba_Lma", ba_Lma)
	trees:swap("ba_Lku", ba_Lku)
	trees:swap("ba_Lko", ba_Lko)
end

local function update_G(trees)
	local ba = trees:bandv("ba")
	local spe = trees:bandv("spe"):vmask()
	return ba:sum(), ba:mask(spe, enum.species.manty):sum()
end

local function recalc_ba_plots()
	local trees = plots:bandv("trees")

	for i=0, plots:len()-1 do
		update_ba(trees[i])
	end
end

local function update_ba_aggregates_plots()
	local G = plots:newband("G")
	local Gma = plots:newband("Gma")
	local trees = plots:bandv("trees")

	for i=0, plots:len()-1 do
		local t = trees[i]
		update_baL(t)
		G[i], Gma[i] = update_G(t)
	end

	plots:swap("G", G)
	plots:swap("Gma", Gma)
end

local function readplots(data)
	local idx = plots:alloc(#data)
	local trees = plots:bandv("trees")
	local ts = plots:band("ts")
	local mtyyppi = plots:band("mtyyppi")
	local atyyppi = plots:band("atyyppi")
	local time = plots:band("time")

	local ntrees = 0

	for i,p in ipairs(data) do
		local pos = idx + i-1
		ts[pos] = p.ts
		mtyyppi[pos] = import.enum(p.mtyyppi)
		atyyppi[pos] = import.enum(p.atyyppi)
		time[pos] = p.step
		local tvec = Tree:vec()
		ntrees = ntrees + #p.trees
		local tidx = tvec:alloc(#p.trees)
		trees[pos] = tvec

		-- TODO: nollaa BA_L etc. templatella
		local f = tvec:band("f")
		local spe = tvec:band("spe")
		local dbh = tvec:band("dbh")
		local ba = tvec:band("ba")

		for j,t in ipairs(p.trees) do
			local tpos = tidx + j-1
			local tspe = t.spe
			-- Tää ei oo ihan oikea tapa, mutta näin se fortran simulaattorikin käytännössä tekee
			if tspe > 6 then tspe = 6 end
			f[tpos] = t.f
			spe[tpos] = import.enum(tspe)
			dbh[tpos] = t.dbh
			ba[tpos] = t.ba
		end
	end

	update_ba_aggregates_plots()
	print(string.format("Luettiin %d koealaa, yhteensä %d puuta", #data, ntrees))
end

local solve_growstep = fhk.solve("i_d", "sur"):from(Tree)
local solve_ingrowth = fhk.solve("fma", "fku", "fra", "fhi", "fle"):from(Plot)

local function grow_trees(idx)
	fhk.bind(plots, idx)
	local trees = plots:bandv("trees")[idx]

	solve_growstep(trees)
	local i_d = solve_growstep:res("i_d")
	local sur = solve_growstep:res("sur")

	local f = trees:bandv("f")
	local d = trees:bandv("dbh")
	local newf = trees:newband("f")
	local newd = trees:newband("dbh")
	f:mul(sur, newf)
	d:add(i_d, newd)
	trees:swap("f", newf)
	trees:swap("dbh", newd)

	--[[
	local ba = trees:bandv("ba")
	local ind = ba:sorti()
	local balku = trees:band("ba_Lku")
	local balko = trees:band("ba_Lko")
	local spe = trees:band("spe")
	for i=0, trees:len()-1 do
		local j = ind[i]
		print(string.format("[%d]\tspe: 0x%02x\t BALku: %10.5f\t BALko: %10.5f\t d: %10.5f\t f: %10.5f\t ba: %10.5f\t i_d: %10.5f\t sur: %10.5f",
			i, spe[j], balku[j], balko[j], d.data[j], f.data[j], ba.data[j], i_d[j], sur[j]))
	end
	]]
end

local newspe = {
	enum.species.manty,
	enum.species.kuusi,
	enum.species.rauduskoivu,
	enum.species.hieskoivu,
	enum.species.haapa
}

local function ingrowth(idx, newf)
	local nnew = 0

	for i, F in ipairs(newf) do
		if F[idx] > 5.0 then
			nnew = nnew + 1
		end
	end

	if nnew == 0 then
		return
	end

	local trees = plots:bandv("trees")[idx]
	local pos = trees:alloc(nnew)

	local f = trees:band("f")
	local spe = trees:band("spe")
	local dbh = trees:band("dbh")
	
	for i,F in ipairs(newf) do
		if F[idx] > 5.0 then
			f[pos] = F[idx]
			spe[pos] = newspe[i]
			dbh[pos] = 0.8
			pos = pos+1
		end
	end
end

local function ingrowth_plots()
	solve_ingrowth(plots)

	local newf = {
		solve_ingrowth:res("fma"),
		solve_ingrowth:res("fku"),
		solve_ingrowth:res("fra"),
		solve_ingrowth:res("fhi"),
		solve_ingrowth:res("fle"),
	}

	for i=0, plots:len()-1 do
		ingrowth(i, newf)
	end
end

local function update_step()
	local time = plots:band("time")
	local step = plots:band("step")

	for i=0, plots:len()-1 do
		step[i] = math.min(time[i], 5)
		time[i] = time[i] - step[i]
	end
end

local function grow()
	update_step()

	for i=0, plots:len()-1 do
		grow_trees(i)
	end

	ingrowth_plots()
	-- päivitä vasta kun uudet puut syntyneet
	recalc_ba_plots()
	update_ba_aggregates_plots()
end

--------------------------------------------------------------------------------

on("init", function()
	local decode = require "json.decode"
	--local plotsfile = io.open("examples/plot1.json")
	local plotsfile = io.open("examples/plots.json")
	readplots(decode(plotsfile:read("*a")))
	plotsfile:close()
end)

on("grow", function()
	grow()
end)
