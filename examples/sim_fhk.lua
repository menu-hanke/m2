local tpl = obj.obj_a:template { y = 0 }
local solve_y_y2 = obj.obj_a:vsolver {"y", "y2"}

local v = world:create_objvec(obj.obj_a)
world:alloc_objvec(v, tpl, 10)

local y = world:alloc_band(v, id.y)
local y2 = world:alloc_band(v, id.y2)
solve_y_y2(v, {y, y2})

y:add(y2)
world:swap_band(v, id.y, y)
world:swap_band(v, id.y2, y2)
