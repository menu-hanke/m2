local ffi = require "ffi"
local m2 = require "m2"
local Spe = require("categ").spe
local fhk, vmath = m2.fhk, m2.vmath.double

fhk.copylabels(Spe)

local Plot_s = ffi.typeof [[
	struct {
		double ts;
		uint8_t mtyyppi;
		uint8_t atyyppi;
	}
]]

local Plot_d = ffi.typeof [[
	struct {
		double step;
	}
]]

local Trees = m2.soa.from_bands {
	f       = "double",
	spe     = "uint8_t",
	dbh     = "double",
	ba      = "double"
}

-- this also works:
--
--     local Trees = ffi.typeof [[
--         struct {
--             struct vec ___header;
--             double *f;
--             ...
--             double *baL_ko;
--         }
--     ]]
--
--     ffi.metatype(Trees, (m2.soa.reflect(Trees)))

local plot_s = m2.new(Plot_s, "static")
local plot_d = m2.new(Plot_d, "vstack")
local trees = m2.new_soa(Trees)

local subgraph = fhk.subgraph()
	:given(fhk.group("plot", fhk.struct_mapper(Plot_s, plot_s), fhk.struct_mapper(Plot_d, plot_d)))
	:given(fhk.group("tree", fhk.soa_mapper(Trees, trees)))
	:edge(fhk.match_edges {
		{ "=>%1",        fhk.ident },
		{ "=>plot",      fhk.only }
	})

local solve_np = subgraph
	:solve("tree#+dbh") -- kasvu
	:solve("tree#*f") -- lupo
	:solve({"plot#+f[manty]", "plot#+f[kuusi]", "plot#+f[rauduskoivu]", "plot#+f[hieskoivu]",
		"plot#+f[leppa]"}) -- synty
	:create()

--------------------------------------------------------------------------------

local function update_ba()
	trees:newband("ba")
	vmath.area(trees.dbh, #trees, trees.ba)
	vmath.mul(trees.ba, trees.f, #trees)
	vmath.mul(trees.ba, 1/10000.0, #trees)
end

local newspe = { Spe.manty, Spe.kuusi, Spe.rauduskoivu, Spe.hieskoivu, Spe.haapa }

local function ingrowth(fma, fku, fra, fhi, fhle)
	local newf = { fma, fku, fra, fhi, fle }

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
	
	for i,F in ipairs(newf) do
		if F > 5.0 then
			trees.f[pos] = F
			trees.spe[pos] = newspe[i]
			trees.dbh[pos] = 0.8
			pos = pos+1
		end
	end
end

local function natproc()
	local sol = solve_np()

	-- kasvu
	local newd, d = trees:newband("dbh")
	vmath.add(d, sol.tree__dbh, #trees, newd)

	-- lupo
	local newf, f = trees:newband("f")
	vmath.mul(f, sol.tree__f, #trees, newf)

	update_ba()

	-- synty
	ingrowth(
		sol.plot__f_manty_[0],
		sol.plot__f_kuusi_[0],
		sol.plot__f_rauduskoivu_[0],
		sol.plot__f_hieskoivu_[0],
		sol.plot__f_leppa_[0]
	)
end

--------------------------------------------------------------------------------

m2.on("sim:setup", function(state)
	plot_s.ts = state.ts
	plot_s.mtyyppi = state.mtyyppi
	plot_s.atyyppi = state.atyyppi

	local idx = trees:alloc(#state.trees)
	
	local f = trees:newband("f")
	local spe = trees:newband("spe")
	local dbh = trees:newband("dbh")
	local ba = trees:newband("ba")

	for i,t in ipairs(state.trees) do
		local pos = idx + i-1
		f[pos] = t.f
		spe[pos] = math.min(t.spe, 6)
		dbh[pos] = t.dbh
		ba[pos] = t.ba
	end
end)

m2.on("grow", function(step)
	plot_d.step = step
	natproc()
end)

return {
	trees = trees
}
