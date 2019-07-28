local ffi = require "ffi"
local conf = require "conf"
local sim = require "sim"

local function main(args)
	local data = conf.read(args.config)

	local lex = conf.get_lexicon(data)
	local graph = conf.get_fhk_graph(data)
	local S = sim.create(lex)
	local upd = S:create_fhk_update(graph, lex)
	local uset = upd:create_uset("sublevel", "y")

	S:allocv("toplevel", 5)
	local i = 0

	for t in S:iter("toplevel") do
		t.c = ffi.C.packenum(i)
		t.x = 3.14*i
		i = i+1

		local slice = S:allocv("sublevel", 5, t)
		upd:update_slice(slice, uset)
	end

	--[[
	print("--- enter ---")
	S:enter()

	for t in S:iter("toplevel") do
		local oldval = t.c
		t.c = 2
		print("c:", oldval, "-->", t.c)

		for s in S:iter("sublevel", t) do
			local oldx = s["x'"]
			s["x'"] = s["x'"] ^ 2
			print("-> x':", oldx, "-->", s["x'"])
		end
	end

	print("--- rollback ---")
	S:rollback()

	for t in S:iter("toplevel") do
		print("c:", t.c)

		for s in S:iter("sublevel", t) do
			print("-> x':", s["x'"])
		end
	end

	for s in S:iter("sublevel") do
		print("rootlist sublevel x':", s["x'"])
	end
	]]
end

return { main=main }
