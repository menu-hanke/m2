local ffi = require "ffi"
local conf = require "conf"
local exec = require "exec"
local sim = require "sim"

local function init_graph(u, data)
	for _,fv in pairs(data.fhk_vars) do
		if fv.kind == "var" then
			ffi.C.u_link_var(u, fv.fhk_var, fv.src.obj.lexobj, fv.src.lexvar)
		elseif fv.kind == "env" then
			ffi.C.u_link_env(u, fv.fhk_var, fv.src.lexenv)
		elseif fv.kind == "computed" then
			ffi.C.u_link_computed(u, fv.fhk_var, fv.src.name)
		end
	end

	for _,fm in pairs(data.fhk_models) do
		-- store pointers here to prevent gc
		fm.ex_func = exec.from_model(fm)
		ffi.C.u_link_model(u, fm.fhk_model, fm.name, fm.ex_func)
	end
end

local function main(args)
	local data = conf.read(
		get_builtin_file("builtin_lex.lua"),
		args.config
	)
	local lex = conf.create_lexicon(data)
	local s = sim.create(lex)

	local G = conf.create_fhk_graph(data)
	local u = ffi.C.u_create(s._sim, lex, G)
	init_graph(u, data)

	-- inject fhk update set function here,
	-- this is not probably the best place for this but w/e
	s.env.usetv = function(objid, ...)
		local varids = {...}
		local c_varids = ffi.new("lexid[?]", #varids)
		for i,v in ipairs(varids) do
			c_vars[i-1] = v
		end
		return ffi.C.uset_create_vars(u, objid, #varids, varids)
	end

	s:run_script(get_builtin_file("script_test.lua"))
end

return { main=main }
