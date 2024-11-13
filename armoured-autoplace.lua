local enemy_autoplace = require ("__base__/prototypes/entity/enemy-autoplace-utils")
local check_terrain   = settings.startup["ab-enable-moisture-check"].value

function Armoured_get_autoplace_base(distance)
local base = "enemy_autoplace_base(" .. distance ..", 8)"
	if check_terrain then 
		if not mods['alien-biomes'] then
			base = "min("..base..",range_select{input=moisture,from=0.4,to=1,slope=0.05,min=0,max=1})" 
			else
			base = "min("..base..","..
					"min(range_select{input=moisture,from=0.4,to=1,slope=0.05,min=0,max=2},"..
						"range_select{input=temperature,from=18,to=50,slope=1,min=0,max=1}))"
			end
		end
return enemy_autoplace.enemy_spawner_autoplace(base)
end