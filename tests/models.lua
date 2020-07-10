return {
	id            = function(...) return ... end,
	ret1          = function() return 1 end,
	runtime_error = function() error() end,

	ba_sum        = function(k, bas)
		local s = 0
		for i,ba in ipairs(bas) do
			s = s+ba
		end
		return s*k
	end
}
