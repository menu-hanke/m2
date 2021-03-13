local code = require "code"
local ctypes = require "fhk.ctypes"
local ffi = require "ffi"
local C = ffi.C

local function solver_ctype(roots)
	local fields, ctypes = {}, {}

	for _,v in ipairs(roots) do
		table.insert(fields, string.format("$ *%s;", v.name))
		table.insert(ctypes, v.ctype)
	end

	return ffi.typeof(string.format("struct { %s }", table.concat(fields, "")), unpack(ctypes))
end

-- roots:
--     name (required)     name in result cdata, must be a valid C identifier
--     idx (required)      variable index in G
--     ctype (required)    type in result cdata
--     subset              subset to solve.
--                         cdata -> fixed subset
--                         non-cdata -> read key (index table or cdata) from state
--                         nil -> solve full space (requires shape table)
--     nopack              set FHKF_NPACK (don't pack result, requires shape table)
--     group               group index, required if subset is implicit space or nopack is set
local function solver_init(G, roots, static_alloc, runtime_alloc)
	local res_ct = solver_ctype(roots)

	local req = ffi.cast("struct fhk_req *", static_alloc(
		#roots*ffi.sizeof("struct fhk_req"), ffi.alignof("struct fhk_req")
	))

	for i,v in ipairs(roots) do
		req[i-1].idx = v.idx
		req[i-1].flags = 0
		req[i-1].buf = nil
		if type(v.subset) == "cdata" then
			req[i-1].ss = v.subset
		end
	end

	local out = code.new()

	for i,v in ipairs(roots) do
		if v.subset and type(v.subset) ~= "cdata" then
			out:emitf("local __subset_%d = roots[%d].subset", i, i)
		end
	end

	out:emitf([[
		local ffi = require "ffi"
		local C, cast = ffi.C, ffi.cast
		local fhk_ct = require "fhk.ctypes"
		local space, size, ssfromidx = fhk_ct.space, fhk_ct.ss_size, fhk_ct.ssfromidx
		local type = type
		local G, req = G, req
		local res_ctp = res_ctp

		return function(arena, state, shape)
			local res = cast(res_ctp, alloc(%d, %d))
	]], ffi.sizeof(res_ct), ffi.alignof(res_ct))

	for i,v in ipairs(roots) do
		out:emit("do")
		
		if type(v.subset) == "cdata" then
			out:emitf([[
				local buf = alloc(%d, %d)
				req[%d].buf = buf
			]],
			ctypes.ss_size(v.subset)*ffi.sizeof(v.ctype), ffi.alignof(v.ctype),
			i-1)
		elseif v.subset then
			out:emitf([[
				local ss = state[__subset_%d]
				local num
				if type(ss) == "table" then
					num = #ss
					ss = ssfromidx(ss, arena)
				else
					num = size(ss)
				end
				local buf = alloc(num*%d, %d)
				req[%d].ss = ss
				req[%d].buf = buf
			]],
			i,
			ffi.sizeof(v.ctype), ffi.alignof(v.ctype),
			i-1,
			i-1)
		else
			-- fast path for space
			-- TODO: compute the space/size only once per group?
			out:emitf([[
				local buf = alloc(shape[%d]*%d, %d)
				req[%d].ss = space(shape[%d])
				req[%d].buf = buf
			]],
			v.group, ffi.sizeof(v.ctype), ffi.alignof(v.ctype),
			i-1, v.group,
			i-1)
		end

		out:emitf([[
			res.%s = buf
			end
		]], v.name)
	end

	out:emitf([[
		local solver = C.fhk_create_solver(G, arena, %d, req)
		C.fhkS_shape_table(solver, shape)
		return solver, res
		end
	]], #roots)

	return out:compile({
		require = require,
		type    = type,
		req     = req,
		G       = G,
		res_ctp = ffi.typeof("$*", res_ct),
		alloc   = runtime_alloc,
		roots   = roots
	}, string.format("=(initsolver@%p)", roots))()
end

-- obtain should return an arena
local function graph_init(shapef, obtain)
	if not shapef[0] then return obtain end
	local maxshape = #shapef

	local out = code.new()

	for i=0, maxshape do
		out:emitf("local __shape_%d = shapef[%d]", i, i)
	end

	out:emitf([[
		local ffi = require "ffi" 
		local C, cast = ffi.C, ffi.cast
		local fhk_idxp = ffi.typeof "fhk_idx *"
		local obtain = obtain

		return function(state)
			local arena = obtain()
			local shape = cast(fhk_idxp, C.arena_alloc(arena, %d, %d))
	]], (maxshape+1)*ffi.sizeof("fhk_idx"), ffi.alignof("fhk_idx"))

	for i=0, maxshape do
		out:emitf("shape[%d] = __shape_%d(state)", i, i)
	end

	out:emit([[
			return arena, shape
		end
	]])

	return out:compile({
		require = require,
		shapef  = shapef,
		obtain  = obtain
	}, string.format("=(subgraphinit@%p)", shapef))()
end

local function driver(M, umem, loop, alloc, release)
	local out = code.new()

	out:emit([[
		local ffi = require "ffi"
		local C, cast = ffi.C, ffi.cast
		local M, loop, umem_ctp = M, loop, umem_ctp
	]])

	for i=1, #umem.fields do
		out:emitf("local __init_%d = umem.fields[%d].init", i, i)
	end

	local uct = umem:ctype()
	assert(ffi.alignof(uct) <= 16)

	out:emitf([[
		return function(arena, state, solver)
			local D = C.fhkD_create_driver(M, %d, solver, arena)
			local u = cast(umem_ctp, D.umem)
	]], ffi.sizeof(uct))

	for i,field in ipairs(umem.fields) do
		out:emitf("u.%s = __init_%d(state)", field.name, i)
	end

	out:emit([[
			local err = loop(D)
			release(arena)
			if err then error(err) end
		end
	]])

	return out:compile({
		require  = require,
		M        = M,
		loop     = loop,
		umem     = umem,
		umem_ctp = ffi.typeof("$*", uct),
		release  = release,
		error    = error,
	}, string.format("=(driverinit@%p)", M))()
end

local function solver_template()
	-- load is used to compile a new root trace
	-- see: https://github.com/luafun/luafun/pull/33
	return load([[
		local _init, _create, _driver

		return function(state)
			local arena, shape = _init(state)
			local solver, result = _create(arena, state, shape)
			_driver(arena, state, solver)
			return result
		end
	]])()
end

local function bind_solver(template, init, create, driver)
	code.setupvalue(template, "_init", init)
	code.setupvalue(template, "_create", create)
	code.setupvalue(template, "_driver", driver)
end

local function uniq(funs)
	local have = {}
	local ret = {}

	for _,f in ipairs(funs) do
		if not have[f] then
			have[f] = true
			table.insert(ret, f)
		end
	end

	return ret
end

local function shapefunc(funs)
	funs = uniq(funs)
	if #funs == 0 then return end
	if #funs == 1 then return funs[1] end

	local out = code.new()

	for i=1, #funs do
		sf:emitf("local shapef%d = funs[%d]", i, i)
	end

	out:emit([[
		return function(state)
			local shape = shapef1(state)
			local s
	]])

	for i=2, #funs do
		out:emitf([[
			s = shapef%d(state)
			if s ~= shape then goto fail end
		]], i)
	end

	-- hack: `if true` needed or the ::fail:: is a syntax error
	out:emit([[
			if true then
				return shape
			end
::fail::
			error(string.format("groups disagree about shape: %d != %d", shape, s))
		end
	]])

	return out:compile({funs=funs, error=error}, string.format("=(groupshape@%p)", funs))()
end

return {
	graph_init        = graph_init,
	solver_init       = solver_init,
	driver            = driver,
	solver_template   = solver_template,
	bind_solver       = bind_solver,
	shapefunc         = shapefunc
}
