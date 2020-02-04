local instr = require("m2").record()
for i=1, 2 do
	instr.grow()
	instr.operation(i)
end
return instr
