local instr = m2.record()
for i=1, 10 do
	instr.grow(3)
end
return instr
