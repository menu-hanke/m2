---- arg parsing ----------------------------------------

local arg_stream_mt = { __index={} }

local function arg_stream(_next, _state, _var)
	local token = _next(_state, _var)

	return setmetatable({
		_next    = _next,
		_state   = _state,
		token    = token,
		mark     = false
	}, arg_stream_mt)
end

function arg_stream_mt:__call()
	if not self.token then
		error("Expected more input")
	end

	local token = self.token
	self.token = self._next(self._state, token)
	self.mark = true

	return token
end

function arg_stream_mt.__index:unmark()
	self.mark = false
end

local function parse(f, args, start)
	local stream = arg_stream(coroutine.wrap(function()
		local idx = start or 1
		while args[idx] do
			coroutine.yield(args[idx])
			idx = idx+1
		end
	end))

	local result = {}

	while stream.token do
		local token = stream.token
		local ok, err = pcall(f, stream, result)
		if not ok then
			error(string.format("%s\nParser failed here: %s", err, token))
		end

		if not stream.mark then
			error(string.format("Unrecognized option: %s", token))
		end

		stream:unmark()
	end

	return result
end

local function combine(fs)
	return function(stream, result)
		for _,f in ipairs(fs) do
			f(stream, result)
			if stream.mark then
				return
			end
		end
	end
end

local function once(f)
	local mark = false
	return function(stream, result)
		if mark then
			return
		end

		f(stream, result)
		mark = stream.mark
	end
end

local function option(short, f)
	return function(stream, result)
		if stream.token ~= short then
			return
		end

		stream()
		f(result, stream())
	end
end

local function single_option(short, name)
	return option(short, function(result, value)
		result[name] = value
	end)
end

local function multi_option(short, name)
	return option(short, function(result, value)
		if not result[name] then
			result[name] = {}
		end
		table.insert(result[name], value)
	end)
end

local function set_option(short, name)
	return option(short, function(result, value)
		if not result[name] then
			result[name] = {}
		end
		result[name][value] = true
	end)
end

local function flag(short, name)
	local char = short:match("^%-(%w)$")
	if not char then
		error(string.format("flag is not '-<char>': '%s'", short))
	end

	local pattern = "^%-" .. char .. "+$"

	return function(stream, result)
		if not stream.token:match(pattern) then
			return
		end

		result[name] = (result[name] or 0) + #stream.token-1
		stream()
	end
end

local function positional(name)
	return once(function(stream, result)
		result[name] = stream()
	end)
end

local function multi_positional(name)
	return function(stream, result)
		if not result[name] then
			result[name] = {}
		end
		table.insert(result[name], stream())
	end
end

local function def(f)
	local args, options = {}, {}
	local args_help, options_help = {}, {}

	-- "<name>"                  --> positional(name)
	-- "[name]+"                 --> multi_positional(name)
	-- -x, name                  --> single_option(-x, name)
	-- -x, name, multiple=true   --> multi_option(-x, name)
	-- -x, name, set=true        --> set_option(-x, name)
	-- -x, name, flag=true       --> flag(-x, name)
	f(function(opt)
		if opt[1]:sub(1, 1) == "-" then
			local gen = (opt.flag and flag)
						or (opt.set and set_option)
						or (opt.multiple and multi_option)
						or single_option

			table.insert(options, gen(opt[1], opt[2] or opt[1]:sub(2)))
			table.insert(options_help, string.format("\t%s %-17s %s", opt[1], opt[2] or "", opt.help or ""))
			return
		end

		local name, multiple = opt[1]:match("^<(%w+)>$"), false
		if not name then
			name, multiple = opt[1]:match("^%[(%w+)%]%+$"), true
		end
		if not name then
			error(string.format("invalid specifier -> '%s'", name))
		end

		if opt.multiple ~= nil then
			multiple = opt.multiple
		end

		local gen = multiple and multi_positional or positional
		table.insert(args, gen(name))
		table.insert(args_help, string.format("\t%-20s %s", name, opt.help or ""))
	end)

	local fs = {}
	for _,opt in ipairs(options) do table.insert(fs, opt) end
	for _,arg in ipairs(args) do table.insert(fs, arg) end

	local help = {}
	if #args_help > 0 then
		table.sort(args_help)
		table.insert(help, string.format("arguments:\n%s", table.concat(args_help, "\n")))
	end
	if #options_help > 0 then
		table.sort(options_help)
		table.insert(help, string.format("options:\n%s", table.concat(options_help, "\n")))
	end

	return combine(fs), table.concat(help, "\n\n")
end

---- coloring ----------------------------------------

local color_mt = {
	__call = function(self, s)
		return string.format("%s%s\x1b[m", self, s)
	end,
	__tostring = function(self)
		return self.escape
	end
}

local function color(escape)
	return setmetatable({escape=escape}, color_mt)
end

---- output ----------------------------------------

local levels = {
	error   = 2,
	warn    = 1,
	print   = 0,
	verbose = -1,
	debug   = -2
}

local function install_logger(mod)
	local ignore = function() end

	mod.install_logger = function(verbosity, print_)
		print_ = print_ or function(...) print(string.format(...)) end
		mod.verbosity = verbosity
		for name,v in pairs(levels) do
			mod[name] = v >= verbosity and print_ or ignore
		end
	end

	return mod
end

--------------------------------------------------------------------------------

return install_logger({
	parse            = parse,
	combine          = combine,
	once             = once,
	single_option    = single_option,
	multi_option     = multi_option,
	set_option       = set_option,
	flag             = flag,
	positional       = positional,
	multi_positional = multi_positional,
	def              = def,

	reset            = color "\x1b[m",
	bold             = color "\x1b[1m",
	red              = color "\x1b[31m",
	green            = color "\x1b[32m",
	yellow           = color "\x1b[33m",
	blue             = color "\x1b[34m",
	magenta          = color "\x1b[35m",
	cyan             = color "\x1b[36m"
})
