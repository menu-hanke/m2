local ffi = require "ffi"
local conf = require "conf"
local fhk = require "fhk"
local malloc = require "malloc"
local typing = require "typing"

ffi.cdef [[
	struct Lvar_info {
		const char *desc;
		const char *ctype;
		type type;
	};

	struct Lmodel_info {
		const char *desc;
		struct model *model;
	};
]]

-------------------------

local function varinfo(udata)
	return ffi.cast("struct Lvar_info *", udata)
end

local function modelinfo(udata)
	return ffi.cast("struct Lmodel_info *", udata)
end

local function hook_graph(G)
	G.exec_model = function(G, udata, ret, args)
		return modelinfo(udata).model(ret, args)
	end

	G.resolve_var = function(G, udata, value)
		assert(false)
	end

	-- G.chain_solved = nil

	G.debug_desc_var = function(udata)
		return varinfo(udata).desc
	end

	G.debug_desc_model = function(udata)
		return modelinfo(udata).desc
	end
end

local function hook_udata(vars, models, exf)
	for name,fv in pairs(vars) do
		local info = malloc.new("struct Lvar_info")
		info.desc = name
		info.type = fv.type.desc
		info.ctype = fv.type.ctype
		fv.info = info
		fv.fhk_var.udata = info
	end

	for name,fm in pairs(models) do
		local info = malloc.new("struct Lmodel_info")
		info.desc = name
		info.model = exf[name]
		fm.info = info
		fm.fhk_model.udata = info
	end
end

local function get_vars(names, vars)
	local ret = {}
	for _,n in ipairs(names) do
		table.insert(ret, vars[n])
	end
	return ret
end

local function get_cvars(vars)
	local ret = ffi.new("struct fhk_var *[?]", #vars)
	for i,v in ipairs(vars) do
		ret[i-1] = v.fhk_var
	end
	return ret
end

local function set_flag(G, flag, vars)
	local bitmap = ffi.new("fhk_vbmap")
	bitmap.u8 = 0
	bitmap[flag] = 1

	if vars then
		for _,v in ipairs(vars) do
			local idx = v.fhk_var.idx
			G.v_bitmaps[idx].u8 = bit.bor(G.v_bitmaps[idx].u8, bitmap.u8)
		end
	else
		ffi.C.bm_or64(ffi.cast("bm8 *", G.v_bitmaps), G.n_var, ffi.C.bmask8(bitmap.u8))
	end
end

-------------------------

local function reportv(visited, ret, G, fv, reason)
	local idx = tonumber(fv.idx)

	if visited[idx] then
		return
	end

	visited[idx] = true

	local fvinfo = varinfo(fv.udata)
	local bitmap = G.v_bitmaps[fv.idx]

	local r = {
		value  = tonumber(ffi.C.vexportd(fv.value, fvinfo.type)),
		desc   = ffi.string(fvinfo.desc),
		reason = reason,
		given  = bitmap.given == 1,
		solved = bitmap.chain_selected == 1
	}

	table.insert(ret, r)

	if r.given then
		r.cost = 0
	end

	if r.solved and (not r.given) then
		local fm = fv.model
		local fminfo = modelinfo(fm.udata)
		r.model = ffi.string(fminfo.desc)
		r.cost = fv.min_cost

		for i=0, tonumber(fm.n_param)-1 do
			reportv(visited, ret, G, fm.params[i], "parameter")
		end

		for i=0, tonumber(fm.n_check)-1 do
			reportv(visited, ret, G, fm.checks[i].var, "constraint")
		end
	end
end

local function report(G, vars)
	local visited = {}
	local ret = {}

	for _,v in ipairs(vars) do
		reportv(visited, ret, G, v.fhk_var, "root")
	end

	return ret
end

local function maxcol(rep, field, max)
	max = max or 0

	for _,r in ipairs(rep) do
		local x = r[field]
		if x and #x > max then
			max = #x
		end
	end

	return max
end

local function print_report(rep)
	local desc_len = maxcol(rep, "desc", 20)
	local model_len = maxcol(rep, "model", 20)

	print(string.format("%-"..desc_len.."s   %-20s %-"..model_len.."s %-16s %s",
		"Variable",
		"Value",
		"Model",
		"Cost",
		"Status"
	))

	for _,r in ipairs(rep) do
		print(string.format("%-"..desc_len.."s = %-20s %-"..model_len.."s %-16s %s %s",
			r.desc,
			r.value,
			r.model or "",
			r.cost  or "",
			r.given and "given" or (r.solved and "solved" or "failed"),
			r.reason
		))
	end
end

-------------------------

local function readcsv(fname)
	local f = io.open(fname)
	local header = map(split(f:read()), trim)
	local data = {}

	for l in f:lines() do
		local d = map(split(l), tonumber)
		if #d ~= #header then
			error(string.format("Invalid line: %s (expected %d values but have %d)",
				l, #d, #header))
		end
		table.insert(data, d)
	end

	f:close()

	return header, data
end

-------------------------

local function main(args)
	local cfg = conf.read(args.config)
	local G, vars, models = fhk.build_graph(cfg.fhk_vars, cfg.fhk_models)
	local exf = fhk.create_models(vars, models, cfg.calib)
	hook_udata(vars, models, exf)
	hook_graph(G)

	local given, values = readcsv(args.input)
	given = get_vars(given, vars)
	local solve = get_vars(args.vars, vars)
	local csolve = get_cvars(solve)

	local reset_v = ffi.new("fhk_vbmap")
	local reset_m = ffi.new("fhk_mbmap")
	ffi.C.fhk_reset(G, reset_v, reset_m)

	reset_v.given = 1
	reset_v.stable = 1

	set_flag(G, "stable")
	set_flag(G, "given", given)

	for _,d in ipairs(values) do
		ffi.C.fhk_reset(G, reset_v, reset_m)

		set_flag(G, "has_value", given)
		for i,v in ipairs(given) do
			v.fhk_var.value = ffi.C.vimportd(d[i], v.type.desc)
		end
		
		ffi.C.fhk_solve(G, #solve, csolve)

		print("--------------------")
		local rep = report(G, solve)
		print_report(rep)
	end
end

return {
	main = main
}
