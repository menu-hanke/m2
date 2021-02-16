-- input protocol:
--     num()   -> number of entries in this file
--     desc()  -> string describing this input file
--     read(i) -> get the i'th entry in this file

local table_reader_mt = {
	__index = {
		num = function(self) return #self.data end,
		desc = function(self) return self.name end,
		read = function(self, i) return self.data[i] end
	}
}

local function table_reader(name, data)
	if #data == 0 then
		data = {data}
	end

	return setmetatable({
		name = name,
		data = data
	}, table_reader_mt)
end

local function read_json(name)
	local fp = io.open(name, "r")
	local data = require("cjson").decode(fp:read("*a"))
	fp:close()
	return data
end

local function json_reader(name)
	return table_reader(string.format("json:%s", name), read_json(name))
end

local function parse_fmt(fmt)
	local f, fname = fmt:match("^(.-):(.+)$")
	if not f then
		local _, ext = fmt:match("^(.+)%.(.-)$")
		if not ext then
			return
		end

		return ext:lower(), fmt
	end

	return f, fname
end

return {
	read_json = read_json,
	parse_fmt = parse_fmt,
	input = {
		json = json_reader
	}
}
