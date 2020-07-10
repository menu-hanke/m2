local Spe = require("categ").spe

local function sum(xs, spe, spm)
	local s = 0
	for i,x in ipairs(xs) do
		if (not spe) or (bit.band(bit.lshift(1ULL, spe[i]), spm) ~= 0) then
			s = s+x
		end
	end
	return s
end

local function sumL(xs, spe, spm)
	local ind = {}
	for i,_ in ipairs(xs) do
		ind[i] = i
	end

	table.sort(ind, function(a, b) return xs[a] > xs[b] end)

	local ret = {}
	local s = 0
	for _,i in ipairs(ind) do
		ret[i] = s
		if (not spe) or (bit.band(bit.lshift(1ULL, spe[i]), spm) ~= 0) then
			s = s+xs[i]
		end
	end

	return ret
end

local manty = bit.lshift(1ULL, Spe.manty)
local kuusi = bit.lshift(1ULL, Spe.kuusi)

return {
	G        = sum,
	Gmanty   = function(ba, spe) return sum(ba, spe, manty) end,
	baL      = sumL,
	baLmanty = function(ba, spe) return sumL(ba, spe, manty) end,
	baLkuusi = function(ba, spe) return sumL(ba, spe, kuusi) end,
	baLkoivu = function(ba, spe) return sumL(ba, spe, bit.bnot(manty + kuusi)) end
}
