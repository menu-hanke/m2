local instr = record()

for i=1, 2 do
	instr.grow()
	instr.operation()
	instr.grow()
	instr.report(i)
end

print("simulointi alkaa tästä.")
simulate(instr)
