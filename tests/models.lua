local function id(...)
	return ...
end

local function axb(a, x, b)
	return a*x + b
end

local function axby(x, y, a, b)
	if not a then
		a = 1
		b = 2
	end
	return a*x + b*y
end

local function is7(x)
	return x == 7 and 1 or 0
end

local function ret12()
	return 1, 2
end

local function crash()
	error("")
end

return {
	id    = id,
	axb   = axb,
	axby  = axby,
	is7   = is7,
	ret12 = ret12,
	crash = crash
}
