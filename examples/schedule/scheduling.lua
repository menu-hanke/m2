local m2 = require "m2"

local operations = m2.scheduler {
	a = 1,
	b = 2,
	c = 3
}

local x = 1
local _, G = m2.ns.dynamic({"operaatiot"}, "struct { bool eka; bool toka; bool kolmas; }")

local eka = function() G.operaatiot.eka = true end
local toka = function() G.operaatiot.toka = true end
local kolmas = function() G.operaatiot.kolmas = true end

operations:event(0x100)
	:tags("a")
	:check(function() return x > 0 end)
	:run(eka)

operations:event(0x101)
	:tags("a", "b")
	:run(toka)

operations:event(0x102)
	:tags("c")
	:check(function(step, prev) return prev==0 or step-prev > 5 end)
	:run(kolmas)

-- vaihtoehtoisesti sim:branchilla.
-- Huom: tässä kaikki kolme ovat vaihtoehtoja toisilleen
local branch_ops = m2.branch {
	m2.choice(0x100, eka),
	m2.choice(0x101, toka),
	m2.choice(0x102, kolmas)
}

--------------------------------------------------------------------------------

m2.on("grow", function()
	G.operaatiot.eka = false
	G.operaatiot.toka = false
	G.operaatiot.kolmas = false
end)

m2.on("operation", function(vuosi)
	operations(vuosi)
	--branch_ops(vuosi)
end)

m2.on("operation#1", function(vuosi)
	local op = {}

	if G.operaatiot.eka then table.insert(op, "eka") end
	if G.operaatiot.toka then table.insert(op, "toka") end
	if G.operaatiot.kolmas then table.insert(op, "kolmas") end

	op = #op == 0 and "(ei mitään)" or table.concat(op, ", ")
	print(string.format("%sVuonna %f tehtiin operaatiot: %s", string.rep("\t", math.floor(vuosi-1)),
		vuosi, op))
end)
