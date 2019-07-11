local function parse_header(ctx, objname, fieldlist)
	objname = trim(objname)

	if ctx.objs[objname] then
		error(string.format("Object '%s' defined twice", objname))
	end

	local flist = map(split(fieldlist), trim)

	local objdef = {
		name=objname,
		data_nfields=#flist,
		fields={},
		data={}
	}

	for i,f in ipairs(flist) do
		local idsym, name, owner = f:match("(%$?)([^@]+)@?([^@]*)")

		if not name then
			error(string.format("Invalid syntax: %s", f))
		end

		if idsym ~= "" then
			if owner ~= "" then
				-- $id@owner
				if not ctx.objs[owner] then
					error(string.format("No such objdef '%s' (in fielddef: %s)", owner, f))
				end

				objdef.owner = ctx.objs[owner]
				objdef.owner_field_idx = i
			else
				-- $id
				objdef.id_field_idx = i
			end
		else
			-- regular
			table.insert(objdef.fields, name)
		end
	end

	ctx.objs[objname] = objdef
	ctx.active = objdef
end

local function parse_data(ctx, line)
	if not ctx.active then
		error(string.format("Missing header"))
	end

	local fields = map(split(line), trim)

	if #fields ~= ctx.active.data_nfields then
		error(string.format("Invalid number of fields, expected %d have %d (in %s)",
			ctx.active.data_nfields, #fields, ctx.active.name))
	end

	local d = {}
	local id

	for i,f in ipairs(fields) do
		if i == ctx.active.owner_field_idx then
			d.owner = ctx.active.owner.data[f]
			if not d.owner then
				error(string.format("Owner id not found: %s", f))
			end
		elseif i == ctx.active.id_field_idx then
			id = f
		else
			-- TODO: now everything is just converted to number but this should probably
			-- get a list of objdefs from config and check the types from there
			table.insert(d, tonumber(f))
		end
	end

	id = id or (#ctx.active.data+1)
	ctx.active.data[id] = d
end

local function parse_line(ctx, l)
	l = trim(l)

	-- ignore blank lines
	if l == "" then
		return
	end

	-- objdef header
	-- objname: field1, field2, ..., fieldn
	local objname, fieldlist = l:match("^([^:]+):(.+)$")
	if objname then
		return parse_header(ctx, objname, fieldlist)
	end

	-- data line
	-- val1, val2, ..., valn
	return parse_data(ctx, l)
end

local function parse_iter(lines_iter)
	local ret = { objs={} }

	for l in lines_iter do
		parse_line(ret, l)
	end

	return ret
end

local function parse_file(fname)
	local f = io.open(fname)
	local ret = parse_iter(f:lines())
	f:close()
	return ret
end

return {
	parse_iter=parse_iter,
	parse_file=parse_file
}
