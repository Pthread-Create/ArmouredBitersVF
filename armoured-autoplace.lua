local noise = require("noise")
local control_name = "enemy-base"
local enemy_base_control_setting = noise.get_control_setting(control_name)

local tne = noise.to_noise_expression
local litexp = noise.literal_expression

local onehalf_exp = tne(1)/2
local onethird_exp = tne(1)/3



local function peak_to_noise_expression(variable, optimal, range)
  local distance_from_optimal = noise.ridge(variable - optimal, 0, math.huge)
  -- Idea is to have a plateau in the center of the rectangle,
  -- edges that taper off at a consistent slope for all rectangles (so that interactions between rectangles are predictable),
  return range - distance_from_optimal
end

local function plateau_peak_to_noise_expression(variable, optimal, range)
  -- Clamp rectangle-based peaks so that large rectangles don't become
  -- super powerful at their centers, because we want to be able to override
  -- them e.g. with beach peaks or whatever
  return noise.min(peak_to_noise_expression(variable, optimal, range) * 20, 1) 
end

local function volume_to_noise_expression(volume)

  local result = nil
  if (volume["aux_min"] and  volume["aux_max"]) then
    local aux_center = (volume["aux_min"] + volume["aux_max"]) / 2
    local aux_range = math.abs(volume["aux_min"] - volume["aux_max"]) / 2
    local aux_fitness = plateau_peak_to_noise_expression(noise.var("aux"), aux_center, aux_range)
    result = aux_fitness
  end

  if (volume["water_min"] and  volume["water_max"]) then
    local water_center = (volume["water_min"] + volume["water_max"]) / 2
    local water_range = math.abs(volume["water_min"] - volume["water_max"]) / 2
    local water_fitness = plateau_peak_to_noise_expression(noise.var("moisture"), water_center, water_range)
    if(result == nil) then
      result = water_fitness
    else
      result = noise.min(result, water_fitness)
    end
  end

  if (volume["temperature_min"] and  volume["temperature_max"]) then
    local temperature_center = (volume["temperature_min"] + volume["temperature_max"]) / 2
    local temperature_range = math.abs(volume["temperature_min"] - volume["temperature_max"]) / 2
    local temperature_fitness = plateau_peak_to_noise_expression(noise.var("temperature"), temperature_center, temperature_range)
    if(result == nil) then
      result = temperature_fitness
    else
      result = noise.min(result, temperature_fitness)
    end
  end

  if (volume["elevation_min"] and  volume["elevation_max"]) then
    local elevation_center = (volume["elevation_min"] + volume["elevation_max"]) / 2
    local elevation_range = math.abs(volume["elevation_min"] - volume["elevation_max"]) / 2
    local elevation_fitness = plateau_peak_to_noise_expression(noise.var("elevation"), elevation_center, elevation_range)
    if(result == nil) then
      result = elevation_fitness
    else
      result = noise.min(result, elevation_fitness)
    end
  end

  return result
end













local function generate_enemy_base_probability_expression()
  local seed1 = 123
  local pi_over_3 = tne(math.pi)/3

  -- enemy_base_border_width gives the width of the border in which probability ramps up from 0 to 1.
  -- i.e. slope = 1 / border_width, and height = radius / border_width
  -- In practice, a probabilty of about 1/9 will result in a solid carpet of biter bases,
  -- which is why this border width is so high (ignoring blobbiness, most of the inner part of the 'border' would be solid biter bases)
  local enemy_base_border_width = 30

  -- Spots per square meter (should be a very small fraction):
  local frequency_expression = noise.max(0, noise.var("enemy-base-frequency"))
  local spot_radius_expression = noise.max(0, noise.var("enemy-base-radius"))
  -- multiply by spot_radius_expression to keep slope constant:
  local spot_height_expression = spot_radius_expression / enemy_base_border_width
  local spot_quantity_expression = pi_over_3 * spot_radius_expression * spot_radius_expression * spot_height_expression
  -- spot_quantity_expression = noise.compile_time_log("Spot quantity: ", spot_quantity_expression)
  local density_expression = spot_quantity_expression * frequency_expression
  -- density_expression = noise.compile_time_log("Density: ", density_expression)

  local basement_value = -1000

  local spots = tne{
    type = "function-application",
    function_name = "spot-noise",
    arguments = {
      x = noise.var("x"),
      y = noise.var("y"),
      seed0 = noise.var("map_seed"),
      seed1 = tne(seed1),
      region_size = tne(512),
      candidate_point_count = tne(100),
      density_expression = litexp(density_expression), -- low-frequency noise evaluate for an entire region
      spot_quantity_expression = litexp(spot_quantity_expression), -- used to figure out where spots go
      hard_region_target_quantity = tne(false), -- it's fine for large spots to push region quantity past the target
      spot_radius_expression = litexp(spot_radius_expression),
      spot_favorability_expression = litexp(1),
      basement_value = tne(basement_value),
      maximum_spot_basement_radius = tne(128)
    }
  }

  local blob_amplitude_multiplier = 0.2 * spot_height_expression * (0.1 + 0.9 * noise.clamp(noise.var("distance") / 3000, 0, 1))
  local blobs = tne{
    type = "function-application",
    function_name = "factorio-basis-noise",
    arguments = {
      x = noise.var("x"),
      y = noise.var("y"),
      seed0 = noise.var("map_seed"),
      seed1 = tne(seed1),
      input_scale = tne(1/8),
      output_scale = tne(1)
    }
  } + tne{
    type = "function-application",
    function_name = "factorio-basis-noise",
    arguments = {
      x = noise.var("x"),
      y = noise.var("y"),
      seed0 = noise.var("map_seed"),
      seed1 = tne(seed1),
      input_scale = tne(1/24),
      output_scale = tne(1)
    }
  } + tne{
    type = "function-application",
    function_name = "factorio-basis-noise",
    arguments = {
      x = noise.var("x"),
      y = noise.var("y"),
      seed0 = noise.var("map_seed"),
      seed1 = tne(seed1),
      input_scale = tne(1/64),
      output_scale = tne(2)
    }
  }

  blobs = (blobs - 0.5) * blob_amplitude_multiplier - 0.3

  local starting_area_sharpness = 20
  local starting_area_hole = noise.min(0, starting_area_sharpness * (noise.var("distance") / noise.var("starting_area_radius") - 1))

  return spots + blobs + starting_area_hole
end


local enemy_random_seed = 1
local function new_random_seed()
  enemy_random_seed = enemy_random_seed + 1
  return enemy_random_seed
end

local function enemy_autoplace(params)
  distance_factor = params.distance_factor or 1
  order = params.order or "b[enemy]-misc"
  is_turret = params.is_turret or false

  local distance_unit = 312
  local distance_outside_starting_area = noise.var("distance") - noise.var("starting_area_radius")

  -- Units with a higher distance_factor will appear farther out by one
  -- distance_unit per distance_factor
  local distance_height_multiplier = noise.max(0, 1 + (distance_outside_starting_area - distance_unit * distance_factor) * 0.002 * distance_factor)

--[[
local temp_min = 18
local temp_max = 60


local probability_expression = volume_to_noise_expression({

    })]]
local tile_restriction	
local probability_expression
if mods['alien-biomes'] then 
	tile_restriction = alien_biomes.list_tiles(alien_biomes.exclude_tags(alien_biomes.all_tiles(), {'frozen','desert'}))
	probability_expression = volume_to_noise_expression({
	water_min=0.3, 
	water_max=1,
    temperature_min = 18,
    temperature_max = 50	
	})	* 3
	else
	probability_expression = volume_to_noise_expression({
	water_min=0.4, 
	water_max=1,
	})	* 2
	end
	
-- probability_expression = noise.min(probability_expression, water_prob_expression)
  
  probability_expression = noise.min(probability_expression, noise.var("enemy_base_probability") * distance_height_multiplier)


--  local probability_expression = noise.var("enemy_base_probability") * distance_height_multiplier
  -- limit probability so that it never quite reaches 1,
  -- because that would result in stupid-looking squares of biter bases:
  probability_expression = noise.min(probability_expression, 0.25 + distance_factor * 0.05)
  -- Add randomness to the probability so that there's a little bit of a gradient
  -- between different units:
  probability_expression = noise.random_penalty(probability_expression, 0.1, {
    x = noise.var("x") + new_random_seed() -- Include distance_factor in random seed!
  })
  -- log("Probability expression for " .. params.order .. "#" .. distance_factor .. ":")
  -- log(tostring(expression_to_ascii_math(probability_expression)))



  local richness_expression = tne(2)





  return
  {
    control = control_name,
    order = order,
    force = "enemy",
    probability_expression = probability_expression,
    richness_expression = richness_expression,
	tile_restriction = tile_restriction,
  }
end

local function enemy_spawner_autoplace(distance)
  return enemy_autoplace{
    distance_factor = distance,
    order = "b[enemy]-a[spawner]"
  }
end

local function enemy_worm_autoplace(distance)
  return enemy_autoplace{
    distance_factor = distance,
    order = "b[enemy]-b[worm]",
    is_turret = true
  }
end

return
{
  sharpness = sharpness,
  control_name = control_name,
  enemy_autoplace = enemy_autoplace,
  enemy_spawner_autoplace = enemy_spawner_autoplace,
  enemy_worm_autoplace = enemy_worm_autoplace
}







--[[

  data.raw.tile["water-mud"].autoplace = {
    probability_expression = volume_to_noise_expression({
      water_min = 0.9,
      water_max = 1.1,
      temperature_min = 0,
      temperature_max = 100
    })
    + tile_noise_weight * noise.min(scaled_noise_layer_expression("water", 0.25), scaled_noise_layer_expression("water", 0.314))
    + noise.min(0, -1 + noise.var("elevation") / beach_range)
    - 1.15
  }
  
  
  
  --lava
    autoplace = {
    max_probability = 0.01,
    order = "a[doodad]-b[decal]",
    peaks = {
      {
         influence = -1
      },
      {
        infleunce = 0.1,
        noise_layer = "puddle-decal",
        noise_octaves_difference = -2,
        noise_persistence = 0.95,
      },
      {
        influence = 1,
        temperature_optimal = 150,
        temperature_range = 50,
        temperature_max_range = 60,
      }
    },
    sharpness = 0.7,
  },
  ]]