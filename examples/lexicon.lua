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

var "x"
unit "m"
dtype "f64"

var "x'"
unit "m"
dtype "f64"

var "y"
unit "m"
dtype "f64"

-- XXX: Myös "välimuuttujat" pitää olla tässä mukana
var "c"
-- TODO: enumien parseeminen, nyt testeissä käytetään vaat bitenum tyyppejä
-- dtype "species"
dtype "b16"

var "z"
unit "m"
dtype "f64"

-- XXX: tässä pitäis varmaan tukea myös jotain tyyliin
--     dtype(vector("real", "real"))
-- tjsp

--[[
invariant(var.x + var.y > 0)
--]]
