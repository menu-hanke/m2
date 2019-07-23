local ffi = require "ffi"
local conf = require "conf"
local sim = require "sim"

local function main(args)
	local env, data = conf.newconf()
	env.read(args.config)

	local lex, lex_arena = conf.get_lexicon(data)
	local S = sim.create(lex)

	S:allocv("toplevel", 5)
	local i = 0

	for t in S:iter("toplevel") do
		t.c = 1
		print("c:", t.c)

		S:allocv("sublevel", 5, t)
		for s in S:iter("sublevel", t) do
			s["x'"] = i
			i = i+1
		end
	end

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
end

return { main=main }
