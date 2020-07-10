local vmath = require "vmath"
local log = require("log").logger

-- Nelder-Mead optimizer
-- See http://www.scholarpedia.org/article/Nelder-Mead_algorithm
--
-- Implementation notes:
-- (1) The optimizer itself is relatively simple, but the functions to optimize (F) are
--     usually simulators, ie. they do (possibly multiple) full simulation steps,
--     most likely doing fhk calls per each tree etc. This means the optimizer spends
--     almost all of its time calling F.
-- (2) The only possibly computation-heavy parts are the vector operations, but they are
--     already implemented in C, see vmath.c.
-- (3) The optimizer should optimize arbitrary Lua functions.
-- (4) For reasons (1)-(3), the optimizer is written in Lua and not C.

local function createxs(n)
	local xs = {}

	for i=1, n+1 do
		xs[i] = vmath.allocvec(n)
	end

	return xs
end

local function createfs(n)
	local fs = {}

	for i=1, n+1 do
		fs[i] = math.huge
	end

	return fs
end

local optimizer_mt = { __index = {} }

local function create(F, n, opt)
	assert(n >= 2)
	return setmetatable({
		F        = F,
		n        = n,
		xs       = createxs(n),
		fs       = createfs(n),
		x_a      = vmath.allocvec(n), -- preallocated space for temp candidate
		x_b      = vmath.allocvec(n), -- ^
		x_o      = vmath.allocvec(n), -- prealloc space for centroid
		max_iter = opt.max_iter or 1000,
		alpha    = opt.alpha or 1.0,
		gamma    = opt.gamma or 2.0,
		beta     = opt.beta or 0.5,
		sigma    = opt.sigma or 0.5,
		epsilon  = opt.epsilon or 0.0001
	}, optimizer_mt)
end

function optimizer_mt.__index:newpop(newf)
	for i,x in ipairs(self.xs) do
		newf(x)
		self.fs[i] = self.F(x)
		log:verbose("[%d/%d]: %f -- %s", i, #self.xs, self.fs[i], x)
	end
end

local function psort(xs, fs)
	local f_1, i_1 = math.huge
	local f_n, i_n = -math.huge
	local f_n1, i_n1 = -math.huge

	for i,x in ipairs(xs) do
		local f = fs[i]

		if f < f_1 then
			f_1 = f
			i_1 = i
		end

		if f > f_n then
			f_n = f
			i_n = i

			if f_n > f_n1 then
				f_n, f_n1 = f_n1, f_n
				i_n, i_n1 = i_n1, i_n
			end
		end
	end

	return i_1, i_n, i_n1
end

local function centroid(x_o, xs, i_n1, n)
	-- start with
	--   x_o <- xs[1] + xs[2]
	-- since it's a bit faster than
	--   x_o <- xs[1]
	--   x_o <- x_o + xs[2]
	xs[1]:add(xs[2], x_o)

	for i=3, n+1 do
		x_o:add(xs[i])
	end

	-- Now x_o <- sum(xs), to get the centroid excluding x_n1 we do
	-- x_o <- (x_o - x_n1) / n
	x_o:sub(xs[i_n1])
	x_o:mul(1/n)
end

function optimizer_mt:__call()
	local F = self.F
	local n = self.n
	local xs = self.xs
	local fs = self.fs
	local x_o = self.x_o
	local best, best_f = nil, math.huge

	for niter=1, self.max_iter do
		local i_1, i_n, i_n1 = psort(xs, fs)

		if fs[i_1] < best_f then
			log:verbose("%d/%d: %f -> %f", niter, self.max_iter, best_f, fs[i_1])
			best = xs[i_1]
			best_f = fs[i_1]
		end

		if math.abs(fs[i_1] - fs[i_n1]) < self.epsilon*fs[i_n1] then
			log:verbose("%d/%d: converged: %f", niter, self.max_iter, best_f)
			break
		end

		centroid(x_o, xs, i_n1, n)

		local x_r = self.x_a
		xs[i_n1]:refl(self.alpha, x_o, x_r)
		local f_r = F(x_r)

		if f_r < fs[i_1] then
			-- Reflected point is best, expand
			-- (note: this step is equivalent to reflecting again with alpha*gamma)
			local x_e = self.x_b
			x_r:refl(-self.gamma, x_o, x_e)
			local f_e = F(x_e)

			if f_e < f_r then
				-- Expanded point improves reflection, accept it
				xs[i_n1], self.x_b = self.x_b, xs[i_n1]
				fs[i_n1] = f_e
			else
				xs[i_n1], self.x_a = self.x_a, xs[i_n1]
				fs[i_n1] = f_r
			end

			goto continue
		end

		if f_r < fs[i_n] then
			-- Reflection is between best and second-worst, accept it
			xs[i_n1], self.x_a = self.x_a, xs[i_n1]
			fs[i_n1] = f_r
			goto continue
		end 

		if f_r < fs[i_n1] then
			-- Outside contraction
			local x_c = self.x_b
			x_r:refl(-self.beta, x_o, x_c)
			local f_c = F(x_c)

			if f_c < f_r then
				xs[i_n1], self.x_b = self.x_b, xs[i_n1]
				fs[i_n1] = f_c
				goto continue
			end
		else
			-- Inside contraction
			local x_c = self.x_b
			x_r:refl(self.beta, x_o, x_c)
			local f_c = F(x_c)

			if f_c < fs[i_n1] then
				xs[i_n1], self.x_b = self.x_b, xs[i_n1]
				fs[i_n1] = f_c
				goto continue
			end
		end

		-- Nothing improved solution, shink the simplex around best point
		-- (save 1 simulator call by skipping i_1)

		do
			local sigma = 1 - self.sigma
			local x_1 = xs[i_1]

			for i=1, i_1-1 do
				xs[i]:refl(sigma, x_1)
				fs[i] = F(xs[i])
			end

			for i=i_1+1, n+1 do
				xs[i]:refl(sigma, x_1)
				fs[i] = F(xs[i])
			end
		end

		::continue::
	end

	self.solution = best
	self.solution_f = best_f
end

return { optimizer=create }
