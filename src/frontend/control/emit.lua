local code = require "code"
local cfg = require "control.cfg"

-- protocol:
-- every function takes 3 parameters:
--   stack: the call stack
--   idx: call stack top
--   continue: entry at the top of call stack (ie. stack[idx+1])
-- to continue, adjust call stack and call continue.
-- you can continue multiple times.
-- branch functions do not return a value.
--
-- some patterns:
--
-- * call f and then return to g:
--   stack[idx+1] = continue
--   return f(stack, idx+1, g)
--
-- * tail call f:
--   return f(stack, idx, continue)
--
-- * return:
--   return continue(stack, idx-1, stack[idx])

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
				return function(stack, idx, continue)
					return _target(stack, idx, continue)
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
		return function(stack, idx, continue)
			return continue(stack, idx-1, stack[idx])
		end
	]], "nothing")()
end

-- equivalent to throwing an exception/longjmping out of the instruction
-- (to the previous branchpoint)
local exit_insn = function(stack, idx, continue) end
local function emit_exit()
	return exit_insn
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

		return function(stack, idx, continue)
			local rv = _f(%s)
			if rv == false then return end
			if rv ~= nil then
				return rv(stack, idx, continue)
			end
			return continue(stack, idx-1, stack[idx])
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

		return function(stack, idx, continue)
			local rv = _f(%s)
			if rv == false then return end
			if rv ~= nil then
				stack[idx+1] = continue
				return rv(stack, idx+1, _next)
			end
			return _next(stack, idx, continue)
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
		
		return function(stack, idx, continue)
			stack[idx+1] = continue
			return _call(stack, idx+1, _next)
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
	src:emitf("%s continue(stack, idx-1, stack[idx])", istail and "return" or "")
end

local function emit_branch_call(src, upvalues, call, istail, id)
	id = string.format("_branch_%s", id)
	upvalues[id] = call
	src:emitf("%s %s(stack, idx, continue)", istail and "return" or "", id)
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
		return exit_insn
	end

	if #node.edges == 1 then
		return emit(node.edges[1])
	end

	local src = code.new()
	local upvalues = { _sim = sim }
	src:emit([[
		return function(stack, idx, continue)
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
	exit_insn = exit_insn,
	primitive = emit_primitive,
	all       = emit_all,
	any       = emit_any,
	compile   = compile
}
