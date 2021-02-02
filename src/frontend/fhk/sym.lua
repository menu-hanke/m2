local symtable_mt = {

	__call = function(self, kind, idx)
		if self[kind] and self[kind][idx] then
			return self[kind][idx]
		else
			return string.format("%s<%d>", kind, idx)
		end
	end

}

local function symbols()
	return setmetatable({
		var    = {},
		model  = {}
	}, symtable_mt)
end

return {
	symbols = symbols
}
