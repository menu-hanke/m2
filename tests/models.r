axb <- function(a, x, b){
	a*x + b
}

axby <- function(x, y, a=1, b=2){
	a*x + b*y
}

is7 <- function(x){
	as.double(x == 7)
}

ret12 <- function(){
	c(1, 2)
}

crash <- function(){
	stop("")
}
