lerp5 <- function(f){
	function(step, ...){
		r <- f(...)
		(r * step/5)
	}
}

exp5 <- function(f){
	function(step, ...){
		r <- f(...)
		(r ^ (step/5))
	}
}

growf <- function(f){
	function(mtyyppi, d, G, ...){
		if(d < 0.001)
			return(0.01)

		G <- min(max(G, 1.0), 80.0)
		d <- min(max(d, 0.8), 70.0)
		omt <- as.integer(mtyyppi < 3)
		vt  <- as.integer(mtyyppi == 4)
		ct  <- as.integer(mtyyppi > 4)

		gro <- f(omt, vt, ct, d, G, ...)
		gro <- min(max(gro, 0.001), 5.0)
		gro
	}
}

survivf <- function(f){
	function(d, ...){
		d <- min(max(d, 5.0), 150.0)
		a <- f(d, ...)
		a <- min(max(a, 30.0), -30.0)
		a <- exp(a)
		p <- 1.0 / (1.0 + a)
		p
	}
}

#------------------------------------------------------------------------------

gro_manty <- lerp5(growf(function(omt, vt, ct, d, G, ba_L, ts, atyyppi,
	c_0=-7.1552, c_sqrtd=0.4415, c_d=-0.0685, c_logG=-0.2027, c_baL=-0.1236, c_logts=1.1198,
	c_omt=0.1438, c_vt=-0.1754, c_ct=-0.5163, c_suo=-0.2425){

	suo <- as.integer(atyyppi > 1)

	exp(
		c_0
		+ c_sqrtd * sqrt(d)
		+ c_d * d
		+ c_logG * log(G + 1)
		+ c_baL * ba_L/log(d + 1)
		+ c_logts * log(ts)
		+ c_omt * omt
		+ c_vt * vt
		+ c_ct * ct
		+ c_suo * suo
	)
}))

gro_kuusi <- lerp5(growf(function(omt, vt, ct, d, G, ba_L, ba_Lku, ts,
	c_0=-12.7527, c_sqrtd=0.1693, c_d=-0.0301, c_logG=-0.1875, c_baL=-0.0563, c_baLku=-0.0870,
	c_logts=1.9747, c_omt=0.2688, c_vt=-0.2145, c_ct=-0.6179){
	
	exp(
		c_0
		+ c_sqrtd * sqrt(d)
		+ c_d * d
		+ c_logG * log(G + 1)
		+ c_baL * ba_L/log(d + 1)
		+ c_baLku * ba_Lku/log(d + 1)
		+ c_logts * log(ts)
		+ c_omt * omt
		+ c_vt * vt
		+ c_ct * ct
	)
}))

gro_lehti <- lerp5(growf(function(omt, vt, ct, d, G, ba_Lku, ba_Lko, ts, spe,
	c_0=-8.6306, c_sqrtd=0.5097, c_d=-0.0829, c_logG=-0.3864, c_baL=-0.0545, c_logts=1.3163,
	c_omt=0.2566, c_vt=-0.2256, c_ct=-0.3237, c_raha=0.0253){

	raha <- as.integer(spe == 3 || spe == 5)

	exp(
		c_0
		+ c_sqrtd * sqrt(d)
		+ c_d * d
		+ c_logG * log(G + 1)
		+ c_baL * (ba_Lku + ba_Lko)/log(d + 1)
		+ c_logts * log(ts)
		+ c_omt * omt
		+ c_vt * vt
		+ c_ct * ct
		+ c_raha * d * raha
	)
}))

#------------------------------------------------------------------------------

sur_manty <- exp5(survivf(function(d, ba_L, atyyppi,
	c_0=1.41223, c_sqrtd=1.8852, c_d=-0.21317, c_baL=-0.25637, c_suo=-0.39878){

	suo <- as.integer(atyyppi > 1)

	-(
	  c_0
	  + c_sqrtd * sqrt(d)
	  + c_d * d
	  + c_baL * ba_L/log(d + 1)
	  + c_suo * suo
	)
}))

sur_kuusi <- exp5(survivf(function(d, ba_Lku, atyyppi,
	c_0=5.01677, c_sqrtd=0.36902, c_d=-0.07504, c_baLku=-0.2319, c_suo=-0.2319){

	suo <- as.integer(atyyppi > 1)

	-(
	  c_0
	  + c_sqrtd * sqrt(d)
	  + c_d * d
	  + c_baLku * ba_Lku/log(d + 1)
	  + c_suo * suo
	)
}))

sur_lehti <- exp5(survivf(function(d, ba_Lma, ba_Lku, ba_Lko, atyyppi, spe,
	c_0=1.60895, c_sqrtd=0.71578, c_d=-0.08236, c_baLma=-0.04814, c_baLkuko=-0.13481,
	c_suo=-0.31789, c_koivu=0.56311, c_haapa=1.40145){
	
	suo <- as.integer(atyyppi > 1)
	koivu <- as.integer(spe == 3 || spe == 4)
	haapa <- as.integer(spe == 5)

	-(
	  c_0
	  + c_sqrtd * sqrt(d)
	  + c_d * d
	  + c_baLma * ba_Lma/log(d + 1)
	  + c_baLkuko * (ba_Lku + ba_Lko)/log(d + 1)
	  + c_suo * suo
	  + c_koivu * koivu
	  + c_haapa * haapa
	)
}))
