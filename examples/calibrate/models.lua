local function lerp5(step, x)
	return x*step/5
end

local function exp5(step, x)
	return x^(step/5)
end

local function ind(b)
	return b and 1 or 0
end

local function gro_ind(mtyyppi)
	return ind(mtyyppi < 3), ind(mtyyppi == 4), ind(mtyyppi > 4)
end

local function clamp(x, m, M)
	return math.min(math.max(x, m), M)
end

local function gro(step, x)
	return lerp5(step, clamp(x, 0.001, 5.0))
end

local function sur(step, x)
	x = clamp(x, -30.0, 30.0)
	x = math.exp(x)
	return exp5(step, 1.0 / (1.0 + x))
end

--------------------------------------------------------------------------------

local function gro_manty(step, mtyyppi, d, G, ba, ba_L, ts, atyyppi,
	c_0, c_sqrtd, c_d, c_logG, c_baL, c_logts, c_omt, c_vt, c_ct, c_suo)

	-- either all coefficients should be given or none
	-- if none given use defaults
	if not c_0 then
		c_0     = -7.1552
		c_sqrtd = 0.4415
		c_d     = -0.0685
		c_logG  = -0.2027
		c_baL   = -0.1236
		c_logts = 1.1198
		c_omt   = 0.1438
		c_vt    = -0.1754
		c_ct    = -0.5163
		c_suo   = -0.2425
	end

	G = clamp(G, 1.0, 80.0)
	d = clamp(d, 0.8, 70.0)
	local omt, vt, ct = gro_ind(mtyyppi)
	local suo = ind(atyyppi > 1)

	return gro(step, math.exp(
		c_0
		+ c_sqrtd * math.sqrt(d)
		+ c_d * d
		+ c_logG * math.log(G + 1)
		+ c_baL * (ba_L + ba/2)/math.log(d + 1)
		+ c_logts * math.log(ts)
		+ c_omt * omt
		+ c_vt * vt
		+ c_ct * ct
		+ c_suo * suo
	))
end

local function gro_kuusi(step, mtyyppi, d, G, ba, ba_L, ba_Lku, ts,
	c_0, c_sqrtd, c_d, c_logG, c_baL, c_baLku, c_logts, c_omt, c_vt, c_ct)

	if not c_0 then
		c_0     = -12.7527
		c_sqrtd = 0.1693
		c_d     = -0.0301
		c_logG  = -0.1875
		c_baL   = -0.0563
		c_baLku = -0.0870
		c_logts = 1.9747
		c_omt   = 0.2688
		c_vt    = -0.2145
		c_ct    = -0.6179
	end

	G = clamp(G, 1.0, 80.0)
	d = clamp(d, 0.8, 70.0)
	local omt, vt, ct = gro_ind(mtyyppi)

	return gro(step, math.exp(
		c_0
		+ c_sqrtd * math.sqrt(d)
		+ c_d * d
		+ c_logG * math.log(G + 1)
		+ c_baL * (ba_L + ba/2)/math.log(d + 1)
		+ c_baLku * (ba_Lku + ba/2)/math.log(d + 1)
		+ c_logts * math.log(ts)
		--+ c_omt * omt
		-- see Simulator.f
		+ c_logts * omt
		+ c_vt * vt
		+ c_ct * ct
	))
end

local function gro_lehti(step, mtyyppi, d, G, ba, ba_Lku, ba_Lko, ts, spe,
	c_0, c_sqrtd, c_d, c_logG, c_baL, c_logts, c_omt, c_vt, c_ct, c_raha)

	if not c_0 then
		c_0     = -8.6306
		c_sqrtd = 0.5097
		c_d     = -0.0829
		c_logG  = -0.3864
		c_baL   = -0.0545
		c_logts = 1.3163
		c_omt   = 0.2566
		c_vt    = -0.2256
		c_ct    = -0.3237
		c_raha  = 0.0253
	end

	G = clamp(G, 1.0, 80.0)
	d = clamp(d, 0.8, 70.0)
	local omt, vt, ct = gro_ind(mtyyppi)
	local raha = ind(spe == 3 or spe == 5)

	return gro(step, math.exp(
		c_0
		+ c_sqrtd * math.sqrt(d)
		+ c_d * d
		+ c_logG * math.log(G + 1)
		+ c_baL * (ba_Lku + ba_Lko + ba/2)/math.log(d + 1)
		+ c_logts * math.log(ts)
		+ c_omt * omt
		+ c_vt * vt
		+ c_ct * ct
		+ c_raha * d * raha
	))
end

--------------------------------------------------------------------------------

local function sur_manty(step, d, ba, ba_L, atyyppi,
	c_0, c_sqrtd, c_d, c_baL, c_suo)

	if not c_0 then
		c_0     = 1.41223
		c_sqrtd = 1.8852
		c_d     = -0.21317
		c_baL   = -0.25637
		c_suo   = -0.39878
	end

	local suo = ind(atyyppi > 1)
	local dd = clamp(d, 5.0, 150.0)

	return sur(step, -(
		c_0
		+ c_sqrtd * math.sqrt(dd)
		+ c_d * dd
		+ c_baL * (ba_L + ba/2)/math.log(d + 1)
		+ c_suo * suo
	))
end

local function sur_kuusi(step, d, ba, ba_Lku, atyyppi,
	c_0, c_sqrtd, c_d, c_baLku, c_suo)

	if not c_0 then
		c_0     = 5.01677
		c_sqrtd = 0.36902
		c_d     = -0.07504
		c_baLku = -0.2319
		c_suo   = -0.2319
	end

	local suo = ind(atyyppi > 1)
	local dd = clamp(d, 5.0, 150.0)

	return sur(step, -(
		c_0
		+ c_sqrtd * math.sqrt(dd)
		+ c_d * dd
		+ c_baLku * (ba_Lku + ba/2)/math.log(d + 1)
		+ c_suo * suo
	))
end

local function sur_lehti(step, d, ba, ba_Lma, ba_Lku, ba_Lko, atyyppi, spe,
	c_0, c_sqrtd, c_d, c_baLma, c_baLkuko, c_suo, c_koivu, c_haapa)

	if not c_0 then
		c_0       = 1.60895
		c_sqrtd   = 0.71578
		c_d       = -0.08236
		c_baLma   = -0.04814
		c_baLkuko = -0.13481
		c_suo     = -0.31789
		c_koivu   = 0.56311
		c_haapa   = 1.40145
	end

	local suo = ind(atyyppi > 1)
	local dd = clamp(d, 5.0, 150.0)
	local koivu = ind(spe == 3 or spe == 4)
	local haapa = ind(spe == 5)

	return sur(step, -(
		c_0
		+ c_sqrtd * math.sqrt(dd)
		+ c_d * dd
		+ c_baLma * ba_Lma/math.log(d + 1)
		+ c_baLkuko * (ba_Lku + ba_Lko + ba/2)/math.log(d + 1)
		+ c_suo * suo
		+ c_koivu * koivu
		+ c_haapa * haapa
	))
end

--------------------------------------------------------------------------------

local function ingrowth_manty(step, ts, G, mtyyppi,
	c_0, c_logts, c_sqrtG, c_omt, c_vt)

	if not c_0 then
		c_0     = -7.6090
		c_logts = 2.0480
		c_sqrtG = -0.4760
		c_omt   = -1.4570
		c_vt    = 0.7510
	end

	G = clamp(G, 1.0, 80.0)
	local omt = ind(mtyyppi < 3)
	local vt = ind(mtyyppi == 4)

	return lerp5(step, math.exp(
		c_0
		+ c_logts * math.log(ts)
		+ c_sqrtG * math.sqrt(G)
		+ c_omt * omt
		+ c_vt * vt
	))
end

local function ingrowth_kuusi(step, ts, G, Gma, mtyyppi,
	c_0, c_logts, c_sqrtG, c_sqrtGma, c_vtct)

	if not c_0 then
		c_0       = -10.9980
		c_logts   = 2.4930
		c_sqrtG   = -0.6960
		c_sqrtGma = 0.5500
		c_vtct    = -1.6510
	end

	G = clamp(G, 1.0, 80.0)
	Gma = clamp(Gma, 0.0, 60.0)
	local vtct = ind(mtyyppi >= 4)

	return lerp5(step, math.exp(
		c_0
		+ c_logts * math.log(ts)
		+ c_sqrtG * math.sqrt(G)
		+ c_sqrtGma * math.sqrt(Gma)
		+ c_vtct * vtct
	))
end

local function ingrowth_koivu(step, ts, G, Gma, mtyyppi, atyyppi,
	c_0, c_logts, c_sqrtG, c_sqrtGma, c_vtct)

	if not c_0 then
		c_0       = 2.2310
		c_logts   = 0.8130
		c_sqrtG   = -0.7850
		c_sqrtGma = 0.3740
		c_vtct    = -0.6660
	end

	G = clamp(G, 1.0, 80.0)
	Gma = clamp(Gma, 0.0, 60.0)
	local vtct = ind(mtyyppi >= 4)

	local fko = lerp5(step, math.exp(
		c_0
		+ c_logts * math.log(ts)
		+ c_sqrtG * math.sqrt(G)
		+ c_sqrtGma * math.sqrt(Gma)
		+ c_vtct * vtct
	))

	if atyyppi > 1 then
		return fko, 0
	else
		return 0.4*fko, 0.6*fko
	end
end

local function ingrowth_leppa(step, ts, G, mtyyppi,
	c_0, c_logts, c_sqrtG, c_omt, c_vtct)

	if not c_0 then
		c_0     = -18.2750
		c_logts = 3.4620
		c_sqrtG = -0.1710
		c_omt   = 1.0630
		c_vtct  = -0.9490
	end

	G = clamp(G, 1.0, 80.0)
	local omt = ind(mtyyppi < 3)
	local vtct = ind(mtyyppi >= 4)

	return lerp5(step, math.exp(
		c_0
		+ c_logts * math.log(ts)
		+ c_sqrtG * math.sqrt(G)
		+ c_omt * omt
		+ c_vtct * vtct
	))
end

--------------------------------------------------------------------------------

return {
	gro_manty = gro_manty,
	gro_kuusi = gro_kuusi,
	gro_lehti = gro_lehti,
	gro_0     = function() return 0 end,

	sur_manty = sur_manty,
	sur_kuusi = sur_kuusi,
	sur_lehti = sur_lehti,
	sur_1     = function() return 1 end,

	ingrowth_manty = ingrowth_manty,
	ingrowth_kuusi = ingrowth_kuusi,
	ingrowth_koivu = ingrowth_koivu,
	ingrowth_leppa = ingrowth_leppa
}

