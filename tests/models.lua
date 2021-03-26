return {
	id            = function(...) return ... end,
	ret1          = function() return 1 end,
	runtime_error = function() error("model crashed") end,

	ba_sum        = function(k, bas)
		local s = 0
		for i=0, #bas-1 do
			s = s + bas[i]
		end
		return s*k
	end,

	sum_vec       = function(v)
		local s = 0
		for i=0, #v-1 do
			s = s+v[i]
		end
		return s
	end,

	prod_scalar   = function(a, b)
		return a*b
	end,

	seqv          = function(w, v)
		for i=0, #v-1 do
			v[i] = w*i
		end
	end
}
