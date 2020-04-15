local m2 = require "m2"

local soa, vmath = m2.soa, m2.vmath
local Spe = m2.fhk.masks.species

local Plot_s, plot_s = m2.data.static(m2.type {
	ts      = "real",
	mtyyppi = "real",
	atyyppi = "real"
})

local Plot_d, plot_d = m2.data.dynamic(m2.type {
	step    = "real",
	G       = "real",
	G_ma    = "real"
})

local Trees = soa.new(m2.type {
	f       = "real",
	spe     = "mask",
	dbh     = "real",
	ba      = "real",
	baL     = "real",
	baL_ma  = "real",
	baL_ku  = "real",
	baL_ko  = "real"
})

local trees = Trees()

local function mapprefix(x, p)
	local pattern = p .. "#(.*)"
	return function(name)
		name = name:match(pattern)
		name = name and name:gsub("/", "_")
		return name and x:fhk_map(name)
	end
end

local fhk_Plot = m2.fhk.context():given(mapprefix(Plot_s, "plot")):given(mapprefix(Plot_d, "plot"))
local fhk_Tree = m2.fhk.context():given(mapprefix(Trees, "tree")):over(Trees)

local solve_growstep = m2.fhk.solve("tree#+dbh", "tree#*f"):given(fhk_Plot):given(fhk_Tree)
local solve_ingrowth = m2.fhk.solve("+f/ma", "+f/ku", "+f/ra", "+f/hi", "+f/le"):given(fhk_Plot)

local function update_ba()
	soa.newband(trees, "ba")
	vmath.area(trees.dbh, #trees, trees.ba)
	vmath.mul(trees.ba, trees.f, #trees)
	vmath.mul(trees.ba, 1/10000.0, #trees)
end

local function update_baL()
	local ind = vmath.sorti(trees.ba, #trees)
	local spe = vmath.mask(trees.spe, #trees)

	vmath.psumi(trees.ba, ind, #trees, soa.newband(trees, "baL"))
	vmath.psumim(trees.ba, ind, spe, Spe.manty, #trees, soa.newband(trees, "baL_ma"))
	vmath.psumim(trees.ba, ind, spe, Spe.kuusi, #trees, soa.newband(trees, "baL_ku"))
	vmath.psumim(trees.ba, ind, spe, bit.bnot(Spe.manty + Spe.kuusi), #trees, soa.newband(trees, "baL_ko"))
end

local function update_G()
	plot_d.G = vmath.sum(trees.ba, #trees)
	plot_d.G_ma = vmath.summ(trees.ba, vmath.mask(trees.spe, #trees), Spe.manty, #trees)
end

local function grow_trees()
	solve_growstep(trees)
	local newf, f = soa.newband(trees, "f")
	local newd, d = soa.newband(trees, "dbh")
	vmath.mul(f, solve_growstep["tree#*f"], #trees, newf)
	vmath.add(d, solve_growstep["tree#+dbh"], #trees, newd)
end

local newspe = { Spe.manty, Spe.kuusi, Spe.rauduskoivu, Spe.hieskoivu, Spe.haapa }

local function ingrowth()
	solve_ingrowth()

	local newf = {
		solve_ingrowth["+f/ma"],
		solve_ingrowth["+f/ku"],
		solve_ingrowth["+f/ra"],
		solve_ingrowth["+f/hi"],
		solve_ingrowth["+f/le"]
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

	local pos = soa.alloc(trees, nnew)
	
	for i,F in ipairs(newf) do
		if F > 5.0 then
			trees.f[pos] = F
			trees.spe[pos] = newspe[i]
			trees.dbh[pos] = 0.8
			pos = pos+1
		end
	end
end

--------------------------------------------------------------------------------

m2.on("sim:setup", function(state)
	plot_s.ts = state.ts
	plot_s.mtyyppi = state.mtyyppi
	plot_s.atyyppi = state.atyyppi

	local idx = soa.alloc(trees, #state.trees)
	
	local f = soa.newband(trees, "f")
	local spe = soa.newband(trees, "spe")
	local dbh = soa.newband(trees, "dbh")
	local ba = soa.newband(trees, "ba")

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
	plot_d.step = step
	grow_trees()
	ingrowth()
	update_ba()
	update_baL()
	update_G()
end)

return {
	trees = trees
}
