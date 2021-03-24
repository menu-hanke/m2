-- why is it unrolled by 4? https://xkcd.com/221/
local function copystack(stack, bottom, top)
	if top - bottom < 4 then
		stack[top+1] = stack[top-3]
		stack[top+2] = stack[top-2]
		stack[top+3] = stack[top-1]
		stack[top+4] = stack[top]
		return stack, bottom+4, top+4
	else
		local j = top
		for i=bottom, top do
			j = j+1
			stack[j] = stack[i]
		end
		return stack, top+1, j
	end
end

local function exit(stack, bottom, top)
	-- do nothing.
end

local function underflow()
	error("control stack underflow!")
end

local function newstack(top)
	-- number of entries here should match the unroll factor in copystack()
	return { underflow, underflow, underflow, top or exit }
end

local function exec(insn, stack, bottom, top)
	stack = stack or newstack()
	bottom = bottom or #stack
	top = top or #stack
	return insn(stack, bottom, top)
end

return {
	copystack = copystack,
	exit      = exit,
	newstack  = newstack,
	exec      = exec,
	call      = call
}
