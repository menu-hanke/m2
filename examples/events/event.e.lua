event "a" {
	blocked_time(5),
	blocked_by { "a", "b" },
	operation.op("a")
}

event "b" {
	blocked_time(5),
	blocked_by { "a", "b" },
	operation.op("b")
}

event "c" {
	blocked_time(15),
	blocked_by { "a", "c" },
	after { "a", "b" },
	operation.op("c")
}
