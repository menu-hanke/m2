obj.test_obj:virtual("x", function()
	return 1234567
end)

local tpl = obj.test_obj:template { y = 0 }
local solve_y_y2 = obj.test_obj:vec_solver {"y", "y2"}

local v = world:create_objvec(obj.test_obj)
world:alloc_objvec(v, tpl, 10)

G.c = 2

local y = world:alloc_band(v, id.y)
local y2 = world:alloc_band(v, id.y2)
solve_y_y2(v, {y, y2})

y:add(y2)
world:swap_band(v, id.y, y)
world:swap_band(v, id.y2, y2)
