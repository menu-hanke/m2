local nogc_ref = {}

function nogc(r)
	nogc_ref[r] = true
end

function yesgc(r)
	nogc_ref[r] = nil
end

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
