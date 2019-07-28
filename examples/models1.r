Mb_1 <- function(x, c) {
	#cat("(R) M1: x =", x, " type =", typeof(x), "\n")
	#cat("(R) M1: c =", c, " type =", typeof(c), "\n")
	return(c*x)
}

Mb_2 <- function(c) {
	return(c+1)
}

Mb_2v2 <- function() {
	return(100)
}

Mb_3 <- function(z) {
	return(z*5)
}

Mb_4 <- function(z) {
	return(z/5)
}

Mc_1 <- function(x) {
	return(exp(x))
}

Mc_2 <- function(xprime) {
	return(log(xprime))
}
