-- These are parameter tables in simo but they're implemented as R "models" here
-- for testing

comp "t_href" dtype "f64"

model "age_increment_test"
	param "species"
	returns "t_href"
	impl "R::examples/simo_parm.r::age_increment_test"
