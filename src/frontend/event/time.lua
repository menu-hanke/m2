---- combined timeline ----------------------------------------

local tl_mt = { __index={} }

local function timeline(tl)
	return setmetatable(tl or {}, tl_mt)
end

function tl_mt.__index:merge(other)
	local merged = false
	local new = timeline()

	for _,s in ipairs(self) do
		if not merged then
			local m = s:merge(other)
			if m then
				merged = true
				s = m
			end
		end

		table.insert(new, s)
	end

	if not merged then
		table.insert(new, other)
	end

	return new
end

---- finite time series ----------------------------------------

local fs_mt = { __index={} }

local function fs(points)
	return setmetatable(points or {}, fs_mt)
end

function fs_mt.__index:merge(other)
	if getmetatable(other) ~= fs_mt then
		return
	end

	local new = {}
	local i,j = 1,1
	local last = -math.huge

	while self[i] or other[j] do
		local a = self[i] or math.huge
		local b = other[j] or math.huge
		local t = math.min(a, b)

		if t > last then
			table.insert(new, t)
			last = t
		end

		if a <= b then
			i = i+1
		end

		if b <= a then
			j = j+1
		end
	end

	return fs(new)
end

---- infinite fixed-step series ----------------------------------------

local lin_mt = { __index={} }

local function lin(start, step)
	return setmetatable({start=start, step=step}, lin_mt)
end

function lin_mt.__index:merge(other)
	if getmetatable(other) ~= lin_mt then
		return
	end

	local step_m = math.min(self.step, other.step)
	local step_M = math.max(self.step, other.step)

	if step_M%step_m == 0 and (self.start-other.start)%step_m == 0 then
		return lin(math.min(self.start, other.start), step_m)
	end
end

return {
	timeline = timeline,
	finite = fs,
	linear = lin
}
