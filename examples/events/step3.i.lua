local insn = m2.record()
for i=1, 3 do
	insn.step(5*i)
end
return insn
