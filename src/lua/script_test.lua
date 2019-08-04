local ffi = require "ffi"

on("grow", function()
	print("kasvatetaan puita")
end)

on("grow#1", function()
	print("kasvatetaan lisää puita?")
end)

on("grow#-100", function()
	print("tämä tehdään ennen puiden kasvatusta")
end)

on("operation", function()
	print("tehdään operaatioita")
end)

on("report", function()
	print("raportoidaan")
end)

function report1()
	--return sim:run("report", grow1)
end

function grow2()
	return sim:run("grow", report1)
end

function operation1()
	return sim:run("operation", grow2)
end

function grow1()
	return sim:run("grow", operation1)
end

--grow1()

local n = 10
local pos = ffi.new("gridpos[?]", n)
local refs = ffi.new("sim_objref[?]", n)
ffi.fill(pos, 8*n)
ffi.C.S_allocv(sim._sim, refs, id.tree, n, pos)

local nd = 5
local del = ffi.new("sim_objref[?]", nd)
del[0] = refs[0]
del[1] = refs[1]
del[2] = refs[2]
del[3] = refs[4]
del[4] = refs[5]
ffi.C.S_deletev(sim._sim, id.tree, nd, del)
