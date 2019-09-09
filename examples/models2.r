tree_d <- function(age, species, SC, a=1, b=2){
	return((a+age)*species*b + SC);
}

tree_h <- function(age, species){
	return(age+species);
}
