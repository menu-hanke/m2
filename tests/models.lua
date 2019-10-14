function id(...)
	return ...
end

function axb(a, x, b)
	return a*x + b
end

function axby(x, y, a, b)
	if not a then
		a = 1
		b = 2
	end
	return a*x + b*y
end

function is7(x)
	return x == 7 and 1 or 0
end

function ret12()
	return 1, 2
end

function crash()
	error("")
end
