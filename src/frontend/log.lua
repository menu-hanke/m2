local levels = {
	error   = 2,
	warn    = 1,
	info    = 0,
	verbose = -1,
	debug   = -2
}

local colors = {
	error = "\27[31m",
	warn  = "\27[33m"
}

local formatters = {
	mes = function(arg, mes) return mes[arg] end,
	log = function(arg, _, logger) return logger[arg] end,
	date = function(fmt) return os.date(fmt) end,
	color = function(w, mes)
		local c = colors[mes.level]
		if not c then return "" end
		return w == ">" and "\27[0m" or c
	end
}

local function logf(level)
	return function(logger, mes, ...)
		return logger:write(logger:format({message=string.format(mes, ...), level=level}), "\n")
	end
end

local function noop() end

local logger_mt = { __index = {} }

local function create(name, fmt, stream, level)
	local ret = setmetatable({
		name   = name,
		fmt    = fmt or "${mes:message}",
		stream = stream or io.stderr
	}, logger_mt)

	ret:setlevel(level or "info")

	return ret
end

function logger_mt.__index:format(mes)
	return self.fmt:gsub("%${([^:}]*):?(.-)}", function(fmt, arg)
		return formatters[fmt](arg, mes, self)
	end)
end

function logger_mt.__index:write(...)
	self.stream:write(...)
end

function logger_mt.__index:setlevel(level)
	local lv = type(level) == "number" and level or levels[level]
	for name,val in pairs(levels) do
		self[name] = val >= lv and logf(name) or noop
	end
end

function logger_mt:__call(mes)
	self:info(mes)
end

return {
	create = create,
	logger = create("m2", "${color:<}${date:%H:%M:%S} m2 -- ${mes:message}${color:>}")
}
