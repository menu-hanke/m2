-- XXX: Nää species yms. yleiset enumit on varmaan määritelty metsäsimulaattorissa,
-- mutta tässä nyt esimerkki miten konffitiedostossa voi määritellä omiakin tyyppejä
enum("species", {
	[1]="Pinus sylvestris",
	[2]="Picea abies",
	[3]="Betula pendula",
	[4]="Betula pubescens",
	[5]="Populus tremula",
	[6]="Alnus incana",
	[7]="Alnus glutinosa",
	[8]="other coniferous",
	[9]="other decidious"
})

obj "obj_a"
	resolution(2)

	var "y"
		unit "m"
		dtype "f64"

obj "obj_b"
	resolution(2)
	
	var "z"
		unit "m"
		dtype "f32"

env "x"
	resolution(0)
	dtype "f64"

env "c"
	resolution(4)
	dtype "b16"

-- These are computed vars only in fhk graph but they must still be declared here
-- because typing info is needed to call the models.
-- An alternative solutin would be to provide the function signature in model def like:
--     model "Mb_1(x:f64, c:b16) -> y:f64"
-- (this duplicates some info but maybe that also helps to prevent typos, idk?)
var "x'"
	dtype "f64"

var "w"
	dtype "f64"
