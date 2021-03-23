local ffi = require "ffi"

local function typeset(...)
	local s = {}
	for _,x in ipairs({...}) do
		if type(x) == "cdata" or type(x) == "string" then
			x = tonumber(ffi.typeof(x))
		elseif type(x) == "table" then -- refct
			x = x.typeid or error(string.format("expected a refct: %s", x))
		elseif type(x) ~= "number" then
			error(string.format("expected a ctypeid: %s", x))
		end
		table.insert(s, x)
	end
	table.sort(s)
	return s
end

local function intersect(A, B)
	if not A then return B end
	if not B then return A end

	local C = {}
	local i, j = 1, 1

	while i <= #A and j <= #B do
		local a, b = A[i], B[j]
		if a < b then
			i = i+1
		elseif b < a then
			j = j+1
		else
			table.insert(C, a)
			i = i+1
			j = j+1
		end
	end

	return C
end

-- XXX: very big hack ahead: we would like to store a set of possible ctypes a variable
-- can have, and then later use that knowledge to cast model parameters. we can use the
-- wonderful ffi-reflect to obtain info about type definitions, but that doesn't give us
-- the tools to actually instantiate them. here's how this hack works: internally,
-- ctype objects are just boxed ctype ids. we would like a ctype object with our own
-- ctype id, but there's no api function to do this. so we do the obvious thing.
-- we ask luajit for a dummy ctype object and (this is the dangerous part) modify
-- the boxed ctypeid to counterfeit our own ctype reference
-- note: this probably works also without gc64, but i haven't tested
-- note: this obviously should be replaced with a better method, but currently i don't
--       think one exists.
local function ctfromid(id)
	-- it doesn't matter what type this holds, we will overwrite it
	local dummy = ffi.typeof("void")

	-- %p gives the cdataptr address (hex)
	local cdataptr = ffi.cast("uint32_t *", tonumber(string.format("%p", dummy):sub(3), 16))

	-- la-la la-la la~ 🎵
	-- let's do something that we shouldn't do~ 🎵
	cdataptr[0] = id

	-- dummy now refers to our ctype!
	return dummy
end
jit.off(ctfromid) -- obviously

local function typeset_tostring(ts)
	local names = {}
	for _,ctid in ipairs(ts) do
		table.insert(names, tostring(ctfromid(ctid)))
	end
	return string.format("{%s}", table.concat(names, ", "))
end

return {
	typeset          = typeset,
	intersect        = intersect,
	ctfromid         = ctfromid,
	typeset_tostring = typeset_tostring
}
