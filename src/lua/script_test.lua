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

local year = sim:evec(env.year)
year:set(0)
print("year is:", year.data[0])
print("increment!")
year:add(1)
print("now it is: ", year.data[0])
