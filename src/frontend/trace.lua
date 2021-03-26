local trace_mt = {
	__call = function(self, event, ...)
		if self[event] then
			self[event](...)
		end
	end
}

return setmetatable({}, trace_mt)
