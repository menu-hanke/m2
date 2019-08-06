local ffi = require "ffi"

local tree_tpl = template(id.tree, {
	[id.h] = 3.14
})

local bigtree_tpl = template(id.tree, {
	[id.h] = 100.0
})

on("grow#-1", function()
	print("istutetaan puita")
	local trees = sim:create_objs(tree_tpl, {0, 1, 2, 3, 4, 5})
end)

on("grow", function()
	print("kasvatetaan puita")
	sim:each_objvec(id.tree, function(v)
		local old_h, new_h = sim:swap_band(v, id.h)
		old_h:add(10.0, new_h)
		print("puun[0] pituus:", new_h.data[0])
	end)
end)

on("operation", function()
	return branch({
		choice(0x1, "operation.1"),
		choice(0x2, "operation.2")
	})
end)

on("operation.1", function()
	print("Tehdään operaatio 1: istutetaan yksi puu lisää")
	local tree = sim:create_objs(bigtree_tpl, {0})
	--sim.write1(tree[0], id.h, 100.0)
end)

on("operation.2", function()
	print("Tehdään operaatio 2 ?")
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

grow1()
