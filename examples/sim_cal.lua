globals.new("step")
fhk.expose(globals)

local Plot = obj("Plot", types.plot)
local Tree = obj("Tree", types.tree)
Plot:hint("trees", Tree:refvec())
fhk.expose(Plot)
fhk.expose(Tree)

local plots = Plot:vec()

local function update_ba(idx, G)
	local trees = plots:bandv("trees")[idx]

	local f = trees:band("f")
	local d = trees:bandv("dbh")
	local ba = trees:newbandv("ba")
	d:area(ba.data)
	ba:mul(f)
	ba:mul(1/10000.0) -- XXX: skaalaus että yksiköt menee oikein

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

	G[idx] = ba:sum()
	trees:swap("ba", ba.data)
	trees:swap("ba_L", ba_L)
	trees:swap("ba_Lma", ba_Lma)
	trees:swap("ba_Lku", ba_Lku)
	trees:swap("ba_Lko", ba_Lko)
end

local function readplots(data)
	local idx = plots:alloc(#data)
	local trees = plots:bandv("trees")
	local ts = plots:band("ts")
	local G = plots:band("G")
	local mtyyppi = plots:band("mtyyppi")
	local atyyppi = plots:band("atyyppi")

	local ntrees = 0

	for i,p in ipairs(data) do
		local pos = idx + i-1
		ts[pos] = p.ts
		mtyyppi[pos] = import.enum(p.mtyyppi)
		atyyppi[pos] = import.enum(p.atyyppi)
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

		update_ba(pos, G)
	end

	print(string.format("Luettiin %d koealaa, yhteensä %d puuta", #data, ntrees))
end

local update_growstep = fhk.solve("i_d", "sur"):from(Tree)

local function grow_plot(idx)
	fhk.bind(plots, idx)
	local trees = plots:bandv("trees")[idx]

	update_growstep(trees)
	local i_d = update_growstep:res("i_d")
	local sur = update_growstep:res("sur")

	local f = trees:bandv("f")
	local d = trees:bandv("dbh")
	local newf = trees:newband("f")
	local newd = trees:newband("dbh")
	f:mul(sur, newf)
	d:add(i_d, newd)
	trees:swap("f", newf)
	trees:swap("dbh", newd)
end

local function grow()
	local G = plots:newband("G")

	for i=0, plots:len()-1 do
		grow_plot(i)
		update_ba(i, G)
	end

	plots:swap("G", G)
end

--------------------------------------------------------------------------------

on("init", function()
	local decode = require "json.decode"
	--local plotsfile = io.open("examples/plot1.json")
	local plotsfile = io.open("examples/plots.json")
	readplots(decode(plotsfile:read("*a")))
	plotsfile:close()
end)

on("grow", function(step)
	G.step = step
	for i=1, 100 do
		grow()
	end
end)

--------------------------------------------------------------------------------

local instr = record()

instr.init()
instr.grow(5)

simulate(instr)
