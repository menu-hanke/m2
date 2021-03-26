local cli = require "cli"

---- code generation ----------------------------------------

local function try_format(x)
	local formatter = os.getenv("M2_CODE_FORMATTER")

	if formatter then
		try_format = function(src)
			local proc = io.popen(string.format([[
				%s <<EOF
				%s]].."\nEOF", formatter, src))
			src = proc:read("*a")
			proc:close()
			return src
		end
	else
		try_format = function(src)
			return src
		end
	end

	return try_format(x)
end

local function emit(name, src)
	io.stderr:write(
		cli.magenta "emit",
		" ",
		cli.bold(name),
		"\n",
		cli.magenta "> " .. try_format(src):gsub("\n", cli.magenta "\n> ")
	)
end

---- simulator events ----------------------------------------

local function ioinfo(event, slot, fp, i)
	io.stderr:write(
		cli.green(slot),
		event == "input" and " <- " or " -> ",
		cli.cyan(fp:desc())
	)

	if i and fp:num() > 1 then
		io.stderr:write(" [", i, "/", fp:num(), "]")
	end

	io.stderr:write("\n")
end

---- fhk events ----------------------------------------

local function solvertrace(info)
	require("fhk.debug").trace(info)
end

local function subgraphinfo(info)
	local vars, models, shadows, ufuncs = {}, {}, {}, {}
	for name,_ in pairs(info.full_nodeset.vars) do table.insert(vars, name) end
	for name,_ in pairs(info.full_nodeset.models) do table.insert(models, name) end
	for name,_ in pairs(info.full_nodeset.shadows) do table.insert(shadows, name) end
	for i,ufunc in pairs(info.mapping.umaps) do
		if type(i) == "number" then table.insert(ufuncs, {idx=i, ufunc=ufunc}) end
	end

	table.sort(vars)
	table.sort(models)
	table.sort(shadows)
	table.sort(ufuncs, function(a, b) return a.idx < b.idx end)

	for _,name in ipairs(vars) do
		io.stderr:write(
			cli.green(name),
			cli.yellow " -> "
		)
		local var = info.nodeset.vars[name] 
		if var then
			io.stderr:write( "[", tostring(info.mapping.nodes[var]))
			if var.create then
				io.stderr:write(
					"/",
					cli.cyan(tostring(info.dispatch.vref[info.mapping.nodes[var]]))
				)
			end
			io.stderr:write(
				"] ",
				tostring(var.ctype),
				cli.cyan "  ~", var.cdiff
			)
		else
			io.stderr:write(cli.red "pruned")
		end
		io.stderr:write("\n")
	end

	for _,name in ipairs(shadows) do
		io.stderr:write(
			cli.bold(cli.green(name)),
			cli.yellow " -> "
		)
		local shadow = info.nodeset.shadows[name]
		if shadow then
			io.stderr:write("[", info.mapping.nodes[shadow], "]")
		else
			io.stderr:write(cli.red "pruned")
		end
		io.stderr:write("\n")
	end

	for _,name in ipairs(models) do
		io.stderr:write(
			cli.blue(name),
			cli.yellow " -> "
		)
		local model = info.nodeset.models[name]
		if model then
			io.stderr:write(
				"[",
				tostring(info.mapping.nodes[model]),
				"/",
				cli.cyan(tostring(info.dispatch.modcall[info.mapping.nodes[model]])),
				"] ",
				cli.cyan " +", model.k,
				cli.cyan " *", model.c,
				cli.cyan " >", model.cmin
			)
		else
			io.stderr:write(cli.red "pruned")
		end
		io.stderr:write("\n")
	end

	for _,u in ipairs(ufuncs) do
		io.stderr:write(
			cli.cyan(u.ufunc.name),
			cli.yellow " -> ",
			"[",
			u.idx,
			"/",
			cli.cyan(info.dispatch.mapcall[u.idx]),
			"]\n"
		)
	end
end

--------------------------------------------------------------------------------

return {
	e = { attach={emit=emit}, help="emitted code" },
	s = { attach={subgraph=subgraphinfo}, help="fhk subgraph information" },
	S = { attach={subgraph=solvertrace}, help="fhk solver events (very slow)" },
	p = { attach={ioinfo=ioinfo}, help="simulation progress" }
}
