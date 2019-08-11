local tpl = template(obj.obj_a, {
	[var.y] = 0
})

local s = uset_obj("obj_a", {var.y})

env.c:pvec():or_(1)
print(env.c:pvec().data[0])
world:create_objs(tpl, {0, 1, 2, 3})
fhk_update(s)
