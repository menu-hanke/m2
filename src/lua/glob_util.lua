local ffi = require "ffi"

function trim(str)
	-- ignore second return val
	str = str:gsub("^%s*(.*)%s*$", "%1")
	return str
end

function split(str)
	local ret = {}

	for s in str:gmatch("[^,]+") do
		table.insert(ret, s)
	end

	return ret
end

function map(tab, f)
	local ret = {}

	for k,v in pairs(tab) do
		ret[k] = f(v)
	end

	return ret
end

function collect(tab)
	local ret = {}

	for k,v in pairs(tab) do
		table.insert(ret, v)
	end

	return ret
end

function arena_copystring(a, s)
	local ret = ffi.C.arena_salloc(a, #s+1)
	ffi.copy(ret, s)
	return ret
end

function get_builtin_file(fname)
	-- XXX: this is a turbo hack, it relies on the C code putting this as the first thing
	-- in search path, this should be written in C and replace on M2_LUAPATH
	return package.path:gsub("%?.lua;.*$", fname)
end

function copyarray(ct, src)
	local n = #src
	local ret = ffi.new(ct, n)
	for i,v in ipairs(src) do
		ret[i-1] = v
	end
	return ret, n
end
