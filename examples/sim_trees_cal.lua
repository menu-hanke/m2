globals.static {
	"ts",
	"mtyyppi",
	"atyyppi"
}

globals.dynamic {
	"step",
	"G",
	"Gma"
}

fhk.expose(globals)

local Tree = obj("Tree", types.tree)
fhk.expose(Tree)

local trees = Tree:vec()

local function update_ba()
	local f = trees:band("f")
	local d = trees:bandv("dbh")
	local ba = trees:newbandv("ba")
	d:area(ba.data)
	ba:mul(f)
	ba:mul(1/10000.0) -- XXX: skaalaus että yksiköt menee oikein
	trees:swap("ba", ba.data)
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
	ba:mask(spe, enum.species.manty):psumi(ba_Lma, ind)
	ba:mask(spe, enum.species.kuusi):psumi(ba_Lku, ind)
	ba:mask(spe, bit.bnot(enum.species.manty + enum.species.kuusi)):psumi(ba_Lko, ind)

	trees:swap("ba_L", ba_L)
	trees:swap("ba_Lma", ba_Lma)
	trees:swap("ba_Lku", ba_Lku)
	trees:swap("ba_Lko", ba_Lko)
end

local function update_G()
	local ba = trees:bandv("ba")
	local spe = trees:bandv("spe"):vmask()
	G.G, G.Gma = ba:sum(), ba:mask(spe, enum.species.manty):sum()
end

local solve_growstep = fhk.solve("i_d", "sur"):from(Tree)
local solve_ingrowth = fhk.solve("fma", "fku", "fra", "fhi", "fle"):from(globals)

local function grow_trees()
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
end

local newspe = {
	enum.species.manty,
	enum.species.kuusi,
	enum.species.rauduskoivu,
	enum.species.hieskoivu,
	enum.species.haapa
}

local function ingrowth()
	solve_ingrowth()

	local newf = {
		solve_ingrowth:res("fma")[0],
		solve_ingrowth:res("fku")[0],
		solve_ingrowth:res("fra")[0],
		solve_ingrowth:res("fhi")[0],
		solve_ingrowth:res("fle")[0]
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

on("sim:setup", function(state)
	G.ts = state.ts
	G.mtyyppi = state.mtyyppi
	G.atyyppi = state.atyyppi

	local idx = trees:alloc(#state.trees)

	local f = trees:band("f")
	local spe = trees:band("spe")
	local dbh = trees:band("dbh")
	local ba = trees:band("ba")

	for i,t in ipairs(state.trees) do
		local pos = idx + i-1
		f[pos] = t.f
		spe[pos] = import.enum(math.min(t.spe, 6))
		dbh[pos] = t.dbh
		ba[pos] = t.ba
	end

	update_baL()
	update_G()
end)

on("grow", function(step)
	G.step = step
	grow_trees()
	ingrowth()
	update_ba()
	update_baL()
	update_G()
end)
