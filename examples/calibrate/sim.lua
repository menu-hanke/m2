local m2 = require "m2"
local Spe = m2.masks.species

local Plot, plot = m2.ns()
m2.fhk.config(Plot, {global=true})
Plot.static { "ts", "mtyyppi", "atyyppi" }
Plot.dynamic { "step", "G", "Gma" }

local Tree = m2.obj(m2.types.tree)
trees = Tree:vec() -- globaaleja, kalibrointiskripti lukee näitä

local function update_ba()
	local f = trees:band("f")
	local d = trees:bandv("dbh")
	local ba = trees:newbandv("ba")
	d:area(ba.data)
	ba:mul(f)
	ba:mul(1/10000.0) -- XXX: skaalaus että yksiköt menee oikein
end

local function update_baL()
	local ba = trees:bandv("ba")
	local ba_L = trees:newband("ba_L")
	local ba_Lma = trees:newband("ba_Lma")
	local ba_Lku = trees:newband("ba_Lku")
	local ba_Lko = trees:newband("ba_Lko")
	local ind = ba:sorti()
	local spe = trees:bandv("spe"):vmask()

	ba:psumi(ba_L, ind)
	ba:mask(spe, Spe.manty):psumi(ba_Lma, ind)
	ba:mask(spe, Spe.kuusi):psumi(ba_Lku, ind)
	ba:mask(spe, bit.bnot(Spe.manty + Spe.kuusi)):psumi(ba_Lko, ind)
end

local function update_G()
	local ba = trees:bandv("ba")
	local spe = trees:bandv("spe"):vmask()
	plot.G, plot.Gma = ba:sum(), ba:mask(spe, Spe.manty):sum()
end

local solve_growstep = m2.solve("i_d", "sur"):over(Tree)
local solve_ingrowth = m2.solve("fma", "fku", "fra", "fhi", "fle")

local function grow_trees()
	solve_growstep(trees)
	local f = trees:bandv("f")
	local d = trees:bandv("dbh")
	local newf = trees:newband("f")
	local newd = trees:newband("dbh")
	f:mul(solve_growstep.vars.sur, newf)
	d:add(solve_growstep.vars.i_d, newd)
end

local newspe = { Spe.manty, Spe.kuusi, Spe.rauduskoivu, Spe.hieskoivu, Spe.haapa }

local function ingrowth()
	solve_ingrowth()

	local newf = {
		solve_ingrowth.vars.fma,
		solve_ingrowth.vars.fku,
		solve_ingrowth.vars.fra,
		solve_ingrowth.vars.fhi,
		solve_ingrowth.vars.fle
	}

	local nnew = 0

	for i, F in ipairs(newf) do
		if F > 5.0 then
			nnew = nnew + 1
		end
	end

	if nnew == 0 then
		return
	end

	local pos = trees:alloc(nnew)

	local f = trees:band("f")
	local spe = trees:band("spe")
	local dbh = trees:band("dbh")
	
	for i,F in ipairs(newf) do
		if F > 5.0 then
			f[pos] = F
			spe[pos] = newspe[i]
			dbh[pos] = 0.8
			pos = pos+1
		end
	end
end

--------------------------------------------------------------------------------

m2.on("sim:setup", function(state)
	plot.ts = state.ts
	plot.mtyyppi = state.mtyyppi
	plot.atyyppi = state.atyyppi

	local idx = trees:alloc(#state.trees)

	local f = trees:newband("f")
	local spe = trees:newband("spe")
	local dbh = trees:newband("dbh")
	local ba = trees:newband("ba")

	for i,t in ipairs(state.trees) do
		local pos = idx + i-1
		f[pos] = t.f
		spe[pos] = m2.import_enum(math.min(t.spe, 6))
		dbh[pos] = t.dbh
		ba[pos] = t.ba
	end

	update_baL()
	update_G()
end)

m2.on("grow", function(step)
	plot.step = step
	grow_trees()
	ingrowth()
	update_ba()
	update_baL()
	update_G()
end)
