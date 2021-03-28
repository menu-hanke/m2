(function(){
	 files <- list()
	 anchor <- list()

	 coerce_f <- list(
		 d=as.symbol("as.double"),
		 i=as.symbol("as.integer"),
		 z=as.symbol("as.logical")
	 )

	 function(file, fun, rs){
		 if(!is.element(file, files)){
			 source(file)
			 files <<- append(files, file)
		 }

		 # type coercion is handled in here rather than C code because of R's weird error handling.
		 # if Rf_coerceVector (or any other R call, really) fails outside R code, it longjmps
		 # somewhere(?) and brings down the whole program.

		 f <- .GlobalEnv[[fun]]
		 cexpr <- quote(function(...){ rv <- f(...) })
		 body <- cexpr[[3]]

		 fail <- function(...){ stop(file, "/", fun, ":", ...) }

		 if(length(rs) > 0){
			 body[[length(body)+1]] <- substitute(
				{
					if(is.null(rv)){
						fail("model didn't return a value")
					}
					if(anyNA(rv, recursive=TRUE)){
						fail("model returned NA")
					}
				}
			 , list(fail=fail))

			 if(length(rs) > 1){
				 body[[length(body)+1]] <- substitute(
				 if(length(rv) != nr){
					 fail("expected ", nr, " return values, got ", length(rv))
				 }
				 , list(fail=fail, nr=length(rs)))
			 }

			 if(length(rs) == 1 || (rs[[1]] == tolower(rs[[1]]) && all(rs == rs[[1]]))){
				 # either single return or all scalar returns of same type:
				 # coerce return into a vector of the unique return type
				 body[[length(body)+1]] <- substitute(
					 rv <- coerce(rv)
				 , list(coerce=coerce_f[[tolower(rs[[1]])]]))
			 }else{
				 # multiple mixed return types, coerce into a list
				 body[[length(body)+1]] <- quote(rv <- as.list(rv))
				 for(i in 1:length(rs)){
					 body[[length(body)+1]] <- substitute(
						 rv[[i]] <- coerce(rv[[i]])
					 , list(i=i, coerce=coerce_f[[tolower(rs[[i]])]]))
				 }
			 }
		 }

		 body[[length(body)+1]] <- quote(return(rv))
		 cexpr[[3]] <- body

		 wrapper <- eval(cexpr)
		 deanchor <- function(){ anchor[[fun]] <<- NULL }
		 ret <- list(wrapper, deanchor, fail)
		 anchor[[fun]] <<- ret

		 ret
	 }
})()
