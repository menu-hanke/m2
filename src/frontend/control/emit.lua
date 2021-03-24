local code = require "code"
local cfg = require "control.cfg"
local run = require "control.run"

----- protocol ------
-- every function takes 3 parameters:
--   stack:   the call stack
--   bottom:  active call stack start
--   top:     active call stack top (next jump)
-- the interval stack[bottom..top] (inclusive) is the active call stack.
-- the active call stack must be copied if it is reused (ie. branching).
-- you are allowed to mutate the active call stack, but not stack[0..bottom-1].
-- the active call stack is always non-empty (iow. top >= bottom).
-- branch functions do not return a value.
-- always tail-call the next jump, unless branching. (don't expect a jump to ever return,
-- it's perfectly valid to eg. coroutine.yield() out after the call stack becomes empty).
--
-- some patterns:
--
-- * call f and then return to g:
--   stack[top+1] = g
--   return f(stack, bottom, top+1)
--
-- * tail call f:
--   return f(stack, bottom, top)
--
-- * return:
--   return stack[top](stack, bottom, top-1)
--
-- note: the reason sim is an upvalue but stack is a parameter is to make it easier to
-- let simulator code define user functions (they already have a sim reference in the env).
-- stack could be made an upvalue as well but it probably doesn't have a performance impact.
-- (in fact, parameter might be faster because then it's kept in a register?)

local function compile_node(sim, node, emit, emitted, emitting)
	if type(node) == "function" then
		return node
	end

	if emitted[node] then
		return emitted[node]
	end

	-- this is a hack to make recursion work automatically.
	-- we create a trampoline function which calls the target recursively,
	-- then inject the upvalue when the recursion exits.
	-- this has no runtime penalty (not even extra guards, it's the exact same ir as a direct call)
	-- if the call is compiled.
	-- in the interpreter, it's an extra function call but that doesn't really matter.
	if emitting[node] then
		if type(emitting[node]) ~= "function" then
			emitting[node] = load([[
				local _target
				return function(stack, bottom, top)
					return _target(stack, bottom, top)
				end
			]], string.format("=(trampoline@%s)", node))()
		end
		return emitting[node]
	end

	emitting[node] = true
	local func = node:emit(emit, sim) or error(string.format("cfg not compiled: %s", node))
	emitted[node] = func

	if type(emitting[node]) == "function" then
		code.setupvalue(emitting[node], "_target", func)
	end
	emitting[node] = nil

	return func
end

local function compile(sim, graph)
	local emitted, emitting = {}, {}
	local emit
	emit = function(node) return compile_node(sim, node, emit, emitted, emitting) end
	return emit(graph)
end

---- special controls ----------------------------------------

-- equivalent to an empty function call in a normal program.
-- note: usually you don't want to emit this directly but special case it instead
local function emit_nothing()
	return load([[
		return function(stack, bottom, top)
			return stack[top](stack, bottom, top-1)
		end
	]], "nothing")()
end

-- equivalent to throwing an exception/longjmping out of the instruction
-- (to the previous branchpoint)
local function emit_exit()
	return run.exit
end

---- `primitive` ----------------------------------------
-- emit a "primitive" function call.
-- protocol: the primitive can receive any predefined args.
-- if the primitive returns `false`, execution stops.
-- if the primitive returns a function, control jumps to that function.

local function emit_primitive(node)
	local src = code.new()
	local argt = {}
	for i=1, node.narg do
		src:emitf("local __arg%d = args[%d]", i, i)
		table.insert(argt, string.format("__arg%d", i))
	end

	src:emitf([[
		local _f = f

		return function(stack, bottom, top)
			local rv = _f(%s)
			if rv == false then return end
			if rv ~= nil then
				return rv(stack, bottom, top)
			end
			return stack[top](stack, bottom, top-1)
		end
	]], table.concat(argt, ","))

	return src:compile({
		f    = node.f,
		args = node.args
	}, string.format("=(primitive@%s)", node))()
end

---- `all` ----------------------------------------
-- emit a linear instruction, ie. all { a, b, c } => a -> b -> c

local function emit_chain_primitive(f, narg, args, chain)
	local src = code.new()
	local argt = {}
	for i=1, narg do
		src:emitf("local __arg%d = args[%d]", i, i)
		table.insert(argt, string.format("__arg%d", i))
	end

	src:emitf([[
		local _next, _f = chain, f

		return function(stack, bottom, top)
			local rv = _f(%s)
			if rv == false then return end
			if rv ~= nil then
				stack[top+1] = _next
				return rv(stack, bottom, top+1)
			end
			return _next(stack, bottom, top)
		end
	]], table.concat(argt, ","))

	return src:compile({
		f     = f,
		args  = args,
		chain = chain
	}, string.format("=(chainprimitive@%s->%s)", f, chain))()
end

local function emit_chain_call(call, chain)
	local src = code.new()

	src:emitf([[
		local _next, _call = chain, call
		
		return function(stack, bottom, top)
			stack[top+1] = _next
			return _call(stack, bottom, top+1)
		end
	]])

	return src:compile({
		call  = call,
		chain = chain
	}, string.format("=(chaincall@%s->%s)", call, chain))()
end

local function emit_chain(node, chain, emit)
	if not chain then
		return emit(node)
	end

	if cfg.isprimitive(node) then
		return emit_chain_primitive(node.f, node.narg, node.args, chain)
	else
		return emit_chain_call(emit(node), chain)
	end
end

local function emit_all(node, emit)
	local chain = nil

	for i=#node.edges, 1, -1 do
		local e = node.edges[i]
		if not cfg.isnothing(e) then
			chain = emit_chain(e, chain, emit)
		end
	end

	return chain or cfg.nothing.emit()
end

---- `any` ----------------------------------------
-- emit parallel instructions (branches/choices)
--                     /-> a
-- any { a, b, c } => * -> b
--                     \-> c

-- TODO: special case this:
--     all {
--         pure_guard1,
--         ...
--         pure_guardN,
--         other_edges
--     }
-- to test the pure guards first and only then enter the branch
-- (maybe do it in the optimizer: if this `any` is the only calling edge, then
-- make swap the `all` tag to `guarded-branch`)

local function emit_branch_nothing(src, istail)
	if istail then
		src:emit("return stack[top](stack, bottom, top-1)")
	else
		-- preserve stack top since we are not in tailcall position.
		-- this copies an extra element, that's ok, in optimized graphs `nothing` calls
		-- are always in tail position.
		src:emit([[
			do
				local stack, bottom, top = copystack(stack, bottom, top)
				stack[top](stack, bottom, top-1)
			end
		]])
	end
end

local function emit_branch_call(src, upvalues, call, istail, id)
	id = string.format("_branch_%s", id)
	upvalues[id] = call

	if istail then
		src:emitf("return %s(stack, bottom, top)", id)
	else
		src:emitf("%s(copystack(stack, bottom, top))", id)
	end
end

local function emit_branch(src, upvalues, node, emit, istail, id)
	src:emit("if _sim:enter_branch(fp) then")

	if cfg.isnothing(node) then
		emit_branch_nothing(src, istail)
	else
		emit_branch_call(src, upvalues, emit(node), istail, id)
	end

	src:emit("end")
end

local function emit_any(node, emit, sim)
	if #node.edges == 0 then
		return run.exit
	end

	if #node.edges == 1 then
		return emit(node.edges[1])
	end

	local src = code.new()
	local upvalues = { _sim = sim, copystack = run.copystack }
	src:emit([[
		return function(stack, bottom, top)
			_sim:branch()
			local fp = _sim:fp()
	]])

	for i=1, #node.edges do
		emit_branch(src, upvalues, node.edges[i], emit, i==#node.edges, tostring(i))
	end

	src:emit("end")

	local upv = code.new()
	for name,_ in pairs(upvalues) do
		upv:emitf("local %s = upvalues.%s", name, name)
	end

	return (upv+src):compile({upvalues = upvalues}, string.format("=(any@%s)", node))()
end

--------------------------------------------------------------------------------

return {
	nothing   = emit_nothing,
	exit      = emit_exit,
	primitive = emit_primitive,
	all       = emit_all,
	any       = emit_any,
	compile   = compile
}
