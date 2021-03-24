local cli = require "cli"
local control = require "control"
local cfg = require "control.cfg"
local fhk = require "fhk"
local fio = require "fio"
local misc = require "misc"
local sim = require "sim"
local scripting = require "scripting"

local DEFAULT_FRAMES = 16
local DEFAULT_RSIZE  = 24

local function simopt()
	return {
		nframes = DEFAULT_FRAMES,
		rsize   = 2^DEFAULT_RSIZE,
		config  = {},
		fhkdef  = fhk.def(),
		modules = {},
		input   = {},
		output  = {}
	}
end

local function optenv(opt)
	local env = setmetatable({
		config       = opt.config,
		input        = opt.input,
		output       = opt.output,
		module       = function(name) table.insert(opt.modules, name) end,
		instructions = function(fname) opt.instructions = control.read(fname) end
	}, { __index=_G })
	if opt.fhkdef then
		env.graph = fhk.env(opt.fhkdef.nodeset, opt.fhkdef.impls).read
	end
	env.read = misc.delegate(env, misc.dofile_env)
	return env
end

local function arginsn(exec)
	local insn = {}
	local cenv = control.env()

	for _,e in ipairs(exec) do
		local ok, x = pcall(load(string.format("return sim.%s", e), nil, nil, cenv))
		if not x then error(string.format("failed to load instruction: '%s': %s", e, x)) end
		if type(x) == "function" then x = x() end
		table.insert(insn, x)
	end

	return cfg.all(insn)
end

local function optargs(opt, args)
	opt.nframes = tonumber(args.nframes) or opt.nframes
	opt.rsize = (args.rsize and 2^tonumber(args.rsize)) or opt.rsize

	local env = optenv(opt)

	if args.simfiles then
		for _,fname in ipairs(args.simfiles) do
			env.read(fname)
		end
	end

	if args.input then
		for _,i in ipairs(args.input) do
			local slot,name = i:match("^(.-)=(.+)$")
			if not slot then slot, name = "data", i end
			env.input[slot] = name
		end
	end
	
	-- TODO: outputs
	
	if args.module then
		for _,name in ipairs(args.module) do
			env.module(name)
		end
	end

	if args.instructions then
		env.instructions(args.instructions)
	end

	if args.execute then
		-- this is just to prevent mistakes because it makes no sense
		if args.instructions then
			error("can't use -e with -x")
		end

		opt.instructions = arginsn(args.execute)
	end
end

local function ioinfo(slot, desc, i, num)
	if cli.verbosity <= -1 then
		cli.verbose("%s%s%s: %s%s%s%s",
			cli.green, slot, cli.reset,
			cli.cyan, desc, cli.reset,
			i and num and string.format(" [%d/%d]", i, num) or ""
		)
	end
end

local function io_output(env, output)
	for slot,fp in pairs(output) do
		local io = env.m2.output[slot]
		if io then
			ioinfo(slot, fp:desc())
			io(fp:writer())
		end
	end
end

local function io_input_insn(env, input)
	local fpin = {}

	for slot,def in pairs(input) do
		local reader,fname = fio.parse_fmt(def)
		if not reader or not fio.input[reader] then
			error(string.format("didn't recognize input string: '%s'", def))
		end
		local io = env.m2.input[slot]
		local fp = fio.input[reader](fname)
		if io then
			if fp:num() > 1 then
				table.insert(fpin, {slot=slot, fp=fp, io=io})
			elseif fp:num() == 1 then
				ioinfo(slot, fp:desc())
				io(fp:read(1))
			end
		end
	end

	table.sort(fpin, function(a, b)
		return a.fp:num() < b.fp:num()
	end)

	local insn = {}
	for _,fi in ipairs(fpin) do
		-- XXX: replace this with some kind of loop primitive in the control library
		local file, io = fi.fp, fi.io
		local num, desc = file:num(), file:desc()
		local slot = fi.slot
		local sim = env.m2.sim
		table.insert(insn, function(stack, bottom, top)
			local continue, top = stack[top], top-1
			sim:savepoint()
			local fp = sim:fp()
			for i=1, num do
				sim:enter()
				ioinfo(slot, desc, i, num)
				io(file:read(i))
				continue(control.copystack(stack, bottom, top))
				sim:load(fp)
			end
		end)
	end

	return cfg.all(insn)
end

local function injectio(env)
	env.m2.input = {}
	env.m2.output = {}
end

local function injectlibs(env, opt)
	require("sim").inject(env)
	require("control").inject(env)
	require("soa").inject(env)
	require("vmath").inject(env)
	injectio(env)
	if opt and opt.fhkdef then
		fhk.inject(env, opt.fhkdef)
	end
end

local function initmodules(env, modules)
	for _,mod in ipairs(modules) do
		env.require(mod)
	end
end

local function simulate(opt)
	if not opt.instructions then error("no instructions") end
	local sim = sim.create(opt)
	local env = scripting.env(sim)
	injectlibs(env, opt)
	initmodules(env, opt.modules)
	scripting.hook(env, "start")
	io_output(env, opt.output)
	local ioinsn = io_input_insn(env, opt.input)
	control.patch_exports(opt.instructions, env.m2.export)
	local insn = control.compile(sim, cfg.all({ioinsn, opt.instructions}))
	control.exec(insn)
end

local function main(args)
	local opt = simopt()
	optargs(opt, args)
	simulate(opt)
end

local flags, help = cli.def(function(opt)
	opt { "<simfiles>", help="simulation files", multiple=true }
	opt { "-F", "nframes", help=string.format("allocate {nframes} frames (default: %d)", DEFAULT_FRAMES) }
	opt { "-R", "rsize", help=string.format("allocate 2^{rsize}-sized regions (default: 2^%d)", DEFAULT_RSIZE) }
	opt { "-i", "input", help="input files", multiple=true }
	opt { "-o", "output", help="output files", multiple=true }
	opt { "-m", "module", help="simulator lua modules", multiple=true }
	opt { "-x", "instructions", help="instruction file" }
	opt { "-e", "execute", help="run instructions", multiple=true }
end)

return {
	cli = {
		main = main,
		help = "[simfiles]... [options]...\n\n"..help,
		flags = flags
	}
}
