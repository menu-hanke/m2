id       <- function(x){ x }
id2      <- function(x,y) { list(x,y) }
ret1     <- function(){ 1 }
ret2list <- function(){ list(1,2) }
ret2vec  <- function(){ c(1,2) }
not      <- function(x){ !x }
nop      <- function(){  }
na       <- function(){ NA }
navec    <- function(){ c(1, NA, 3) }
clos     <- function(){ function(){} }

runtime_error <- function(){
	stop("error")
}
