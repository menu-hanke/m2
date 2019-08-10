local tree_tpl = template(id.tree, {
	[id.h] = 3.14
})

local bigtree_tpl = template(id.tree, {
	[id.h] = 100.0
})

local function do_operation(op)
	print("tehdään operaatio: ", op)

	if op == "istutus" then
		world:create_objs(bigtree_tpl, {0})
	end
end

on("grow", function()
	print("istutetaan puita")
	local trees = world:create_objs(tree_tpl, {0, 1, 2, 3, 4, 5})
end)

on("grow#1", function()
	print("kasvatetaan puita")
	for v in world:objvecs(id.tree) do
		local old_h, new_h = world:swap_band(v, id.h)
		old_h:add(10.0, new_h)
		print("puun[0] pituus:", new_h.data[0])
	end
end)

on("operation", function()
	print("haaraudutaan")

	branch(do_operation, {
		choice(0x1, "istutus"),
		choice(0x2, "ei mitään")
	})

	print("haarautuminen loppui")
end)

on("report", function(i)
	local hsum = 0
	for v in world:objvecs(id.tree) do
		-- replace this with vectorized vec:sum(), once that is implemented
		local hvec = v:pvec(id.h)
		for i=0, tonumber(hvec.n)-1 do
			hsum = hsum + hvec.data[i]
		end
	end

	print("raportti[", i, "] h summa: ", hsum)
end)
