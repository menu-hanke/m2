local code = require "code"
local ffi = require "ffi"

local function memoize(sim, f, narg, nret)
	local mp = sim:new(ffi.typeof "uint8_t", "vstack")
	mp[0] = 0

	local argl = {}
	for i=1, narg do table.insert(argl, string.format("@%d", i)) end
	argl = table.concat(argl, ", ")

	local retl = {}
	for i=1, nret do table.insert(retl, string.format("entry.ret%d", i)) end
	retl = table.concat(retl, ", ")

	return code.new()
		:emitf([[
			local max = max
			local _sim, _mp, _f = sim, mp, f
			local _cache = {}

			return function(%s)
				local entry = _cache[ _mp[0] ]
				if entry and %s then return %s end
				_mp[0] = max(_mp[0]+1, _sim:fp())
				entry = _cache[ _mp[0] ]
				if not entry then
					entry = {}
					_cache[ _mp[0] ] = entry
				end
				%s
				%s = _f(%s)
				return %s
			end
		]],
		argl:gsub("@(%d+)", "__arg%1"),
		argl:gsub(", ", " and "):gsub("@(%d+)", "entry.arg%1 == __arg%1"), retl,
		argl:gsub(", ", "\n"):gsub("@(%d+)", "entry.arg%1 = __arg%1"),
		retl, argl:gsub("@(%d+)", "__arg%1"),
		retl)
		:compile({
			max = math.max,
			sim = sim,
			mp  = mp,
			f   = f
		}, string.format("=(memoize@%s)", f))()
end

local function inject(env)
	local sim = env.m2.sim

	function env.m2.memoize(f, nret, narg)
		return memoize(sim, f, narg or debug.getinfo(f).nparams, nret or 1)
	end
end

return {
	memoize = memoize,
	inject  = inject
}
