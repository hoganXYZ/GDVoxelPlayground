extends Node3D

## Automated end-to-end test for the data-driven CA system.
## Run with: godot --path project res://tests/test_ca.tscn
## Prints "CA-TEST PASS <name>" / "CA-TEST FAIL <name>" lines and quits.

var world: VoxelWorld
var failures := 0

# voxelTraceWorld cannot handle perfectly axis-aligned rays (sign(0) == 0
# zeroes the inverse direction), so nudge the ray slightly off-axis.
const DOWN_RAY := Vector3(0.001, -1.0, 0.001)


func _ready() -> void:
	var demo: Node = load("res://demo/demo.tscn").instantiate()
	add_child(demo)
	world = _find_world(demo)
	if world == null:
		_report("find_voxel_world", false)
		_finish()
		return
	_run_tests.call_deferred()


func _find_world(node: Node) -> VoxelWorld:
	if node is VoxelWorld:
		return node
	for child in node.get_children():
		var found := _find_world(child)
		if found != null:
			return found
	return null


func _report(name: String, ok: bool, detail: String = "") -> void:
	if not ok:
		failures += 1
	print("CA-TEST %s %s %s" % ["PASS" if ok else "FAIL", name, detail])


func _finish() -> void:
	print("CA-TEST DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)


func _ticks(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _color16(c: Color) -> int:
	return (int(c.h * 127.0) << 9) | (int(c.s * 15.0) << 5) | int(c.v * 31.0)


func _paint_value(type_id: int, c: Color) -> int:
	return (type_id << 24) | (1 << 16) | _color16(c)


## count voxels of type in a grid-space box, and track max y
## (single batched GPU readback in C++ — per-voxel readbacks stall the frame)
func _census(center: Vector3i, half: int, type_id: int) -> Dictionary:
	return world.census_box(center - Vector3i(half, half, half),
		center + Vector3i(half, half, half), type_id)


## same but over an explicit min..max box (inclusive), for tall thin regions
func _census_box(bmin: Vector3i, bmax: Vector3i, type_id: int) -> Dictionary:
	return world.census_box(bmin, bmax, type_id)


func _run_tests() -> void:
	await _ticks(20) # let the world initialize and settle

	# ---- debug: quick sanity that the world contains terrain at all ----
	var world_solid: Dictionary = world.census_box(Vector3i(0, 0, 0), Vector3i(255, 63, 255), 1)
	print("CA-TEST world census: solid=", world_solid["count"])
	await _ticks(2)
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png("user://ca_test_view.png")
	print("CA-TEST screenshot saved to ", ProjectSettings.globalize_path("user://ca_test_view.png"))

	# ---- find a terrain surface point via a downward raycast (world space) ----
	var probe_origin := Vector3(20.0, 15.5, 27.0) # between the demo point lights
	var hit: Vector3 = world.raycast_world(probe_origin, DOWN_RAY, 100.0)
	var surface := Vector3i(hit)
	var ok_hit: bool = hit.y > 0.0 and hit.y < 64.0
	_report("terrain_raycast", ok_hit, str(hit))
	if not ok_hit:
		_finish()
		return

	# ================= test 1: painted water exists and moves =================
	world.edit_world(probe_origin, DOWN_RAY, 3.0, 100.0, 3) # legacy value 3 = water
	await _ticks(2)
	var before: Dictionary = _census(surface, 5, 2) # type 2 = water
	_report("water_painted", before["count"] > 10, "count=%d" % before["count"])

	await _ticks(60)
	var after: Dictionary = _census(surface, 5, 2)
	# evidence of movement: the sphere cap collapsed, or the water flowed
	# downhill out of the box entirely (void borders eat it at the world edge)
	var ok_flow: bool = after["count"] == 0 or after["max_y"] < before["max_y"] \
		or after["count"] < before["count"]
	_report("water_flows", ok_flow,
		"before(count=%d,max_y=%d) after(count=%d,max_y=%d)" %
		[before["count"], before["max_y"], after["count"], after["max_y"]])
#
	# ================= test 2: lava + water -> solid + steam =================
	# fresh site: pour water and immediately drop lava on it, then look for steam
	var steam_id: int = world.element_set.find_element_id("steam")
	var quench_origin := Vector3(22.0, 15.5, 29.0) # grid (88, ., 116)
	var quench_hit: Vector3 = world.raycast_world(quench_origin, DOWN_RAY, 100.0)
	var quench_surface := Vector3i(quench_hit)
	world.edit_world(quench_origin, DOWN_RAY, 3.0, 100.0, 3) # water
	await _ticks(2)
	world.edit_world(quench_origin + Vector3(0, 0.5, 0), DOWN_RAY, 2.0, 100.0, 4) # lava on top
	await _ticks(20)
	var steam: Dictionary = _census_box(
		Vector3i(quench_surface.x - 8, quench_surface.y, quench_surface.z - 8),
		Vector3i(quench_surface.x + 8, quench_surface.y + 28, quench_surface.z + 8), steam_id)
	_report("quench_makes_steam", steam["count"] > 0, "steam=%d" % steam["count"])

	# ================= test 3: runtime-defined acid dissolves terrain =================
	var acid := VoxelElement.new()
	acid.element_name = "acid"
	acid.movement_class = VoxelElement.MOVEMENT_LIQUID
	acid.density = 1100.0
	acid.base_color = Color(0.6, 0.9, 0.2)
	acid.emission = 0.4
	acid.add_reaction("solid", "", "air", 0.4) # corrode rock away
	var acid_id: int = world.element_set.add_element(acid) # auto re-uploads tables
	_report("acid_registered", acid_id >= 8, "id=%d" % acid_id)

	var acid_origin := Vector3(23.0, 15.5, 26.0) # grid (92, ., 104)
	var acid_hit: Vector3 = world.raycast_world(acid_origin, DOWN_RAY, 100.0)
	var acid_surface := Vector3i(acid_hit)
	var acid_rock_before: Dictionary = _census(acid_surface - Vector3i(0, 2, 0), 3, 1) # type 1 = solid
	world.edit_world(acid_origin, DOWN_RAY, 2.5, 100.0, _paint_value(acid_id, acid.base_color))
	await _ticks(2)
	var acid_present: Dictionary = _census(acid_surface, 4, acid_id)
	_report("acid_painted", acid_present["count"] > 5, "count=%d" % acid_present["count"])

	await _ticks(120)
	var acid_rock_after: Dictionary = _census(acid_surface - Vector3i(0, 2, 0), 3, 1)
	_report("acid_dissolves_rock", acid_rock_after["count"] < acid_rock_before["count"],
		"rock before=%d after=%d" % [acid_rock_before["count"], acid_rock_after["count"]])

	# ================= test 4: runtime cloner via behavior ops =================
	var cloner := VoxelElement.new()
	cloner.element_name = "cloner"
	cloner.movement_class = VoxelElement.MOVEMENT_STATIC
	cloner.base_color = Color(0.9, 0.5, 0.9)
	cloner.add_behavior_op(VoxelBehaviorOp.OP_CREATE, Vector3i(0, 1, 0), "water", "", 0.5,
		VoxelBehaviorOp.SYMMETRY_NONE)
	var cloner_id: int = world.element_set.add_element(cloner)
	_report("cloner_registered", cloner_id >= 8, "id=%d" % cloner_id)

	var cloner_origin := Vector3(27.0, 15.5, 26.0) # grid (108, ., 104)
	var cloner_hit: Vector3 = world.raycast_world(cloner_origin, DOWN_RAY, 100.0)
	var cloner_surface := Vector3i(cloner_hit)
	world.edit_world(cloner_origin, DOWN_RAY, 1.5, 100.0, _paint_value(cloner_id, cloner.base_color))
	await _ticks(60)
	var made_water: Dictionary = _census(cloner_surface + Vector3i(0, 2, 0), 4, 2)
	_report("cloner_emits_water", made_water["count"] > 0, "water=%d" % made_water["count"])
	# remove the cloner and its puddle so the endless water source cannot
	# creep into later censuses
	world.edit_world_at(Vector3(cloner_surface) + Vector3(0, 1, 0), 5.0, 0)

	# ================= test 5: sand (powder class) piles up =================
	var sand_origin := Vector3(34.0, 15.5, 27.5)
	var sand_hit: Vector3 = world.raycast_world(sand_origin, DOWN_RAY, 100.0)
	var sand_surface := Vector3i(sand_hit)
	world.edit_world(sand_origin, DOWN_RAY, 2.5, 100.0, 2) # legacy value 2 = sand
	await _ticks(2)
	var sand_before: Dictionary = _census(sand_surface, 5, 4) # type 4 = sand
	await _ticks(90)
	var sand_after: Dictionary = _census(sand_surface, 5, 4)
	_report("sand_falls", sand_before["count"] > 10 and sand_after["count"] > 0 \
		and sand_after["max_y"] <= sand_before["max_y"],
		"before(count=%d,max_y=%d) after(count=%d,max_y=%d)" %
		[sand_before["count"], sand_before["max_y"], sand_after["count"], sand_after["max_y"]])

	# ================= test 5a: velocity — dropped sand falls multiple cells/tick =================
	# Paint a floating sand ball high above the terrain via the direct-position
	# edit. With velocity integration the ~30-cell drop completes in ~12 ticks;
	# the old one-cell-per-tick CA would still be mid-air. Also asserts mass
	# conservation across the fall (the CAS-duplication tripwire).
	var drop_origin := Vector3(18.5, 15.5, 26.5) # world units; grid (74, ., 106)
	var drop_hit: Vector3 = world.raycast_world(drop_origin, DOWN_RAY, 100.0)
	var drop_surface := Vector3i(drop_hit)
	var ball_center: Vector3 = Vector3(drop_surface) + Vector3(0, 30, 0)
	world.edit_world_at(ball_center, 3.0, 2) # legacy value 2 = sand
	await _ticks(1)
	var drop_box_min := Vector3i(drop_surface.x - 8, drop_surface.y - 4, drop_surface.z - 8)
	var drop_box_max := Vector3i(drop_surface.x + 8, drop_surface.y + 36, drop_surface.z + 8)
	var drop_before: Dictionary = _census_box(drop_box_min, drop_box_max, 4)
	await _ticks(16)
	var drop_after: Dictionary = _census_box(drop_box_min, drop_box_max, 4)
	# grains can legitimately toboggan sideways while settling, so conservation
	# is counted over a much wider box than the drop column
	var drop_wide: Dictionary = _census_box(
		Vector3i(drop_surface.x - 14, drop_surface.y - 4, drop_surface.z - 14),
		Vector3i(drop_surface.x + 14, drop_surface.y + 36, drop_surface.z + 14), 4)
	_report("powder_accelerates", drop_before["count"] > 40 \
		and drop_after["max_y"] <= drop_surface.y + 6,
		"painted=%d max_y_after=%d surface_y=%d" %
		[drop_before["count"], drop_after["max_y"], drop_surface.y])
	_report("powder_mass_conserved", drop_wide["count"] == drop_before["count"],
		"before=%d after_wide=%d after_narrow=%d" %
		[drop_before["count"], drop_wide["count"], drop_after["count"]])

	# ================= test 5c: no tunneling through a plate at high speed =================
	# A wide rock plate floats in the air; sand dropped from high above must be
	# stopped by it — any grain below the plate means the multi-cell path walk
	# skipped an occupied cell.
	var plate_origin := Vector3(25.0, 15.5, 26.5) # world units; grid (100, ., 106)
	var plate_hit: Vector3 = world.raycast_world(plate_origin, DOWN_RAY, 100.0)
	var plate_surface := Vector3i(plate_hit)
	var plate_y := plate_surface.y + 12 # grid is 64 tall; keep the drop inside it
	for off in [Vector3(-4, 0, 0), Vector3(4, 0, 0), Vector3(0, 0, -4), Vector3(0, 0, 4), Vector3(0, 0, 0)]:
		world.edit_world_at(Vector3(plate_surface.x, plate_y, plate_surface.z) + off, 4.0, 1) # rock
	# raised rim so landing grains cannot legitimately roll off the plate —
	# anything found below can only have tunneled through it
	for off in [Vector3(-6, 3, 0), Vector3(6, 3, 0), Vector3(0, 3, -6), Vector3(0, 3, 6)]:
		world.edit_world_at(Vector3(plate_surface.x, plate_y, plate_surface.z) + off, 3.0, 1) # rock rim
	await _ticks(2)
	world.edit_world_at(Vector3(plate_surface.x, plate_y + 8, plate_surface.z), 2.0, 2) # sand above
	await _ticks(20)
	var below: Dictionary = _census_box(
		Vector3i(plate_surface.x - 8, plate_surface.y - 2, plate_surface.z - 8),
		Vector3i(plate_surface.x + 8, plate_y - 6, plate_surface.z + 8), 4)
	var on_plate: Dictionary = _census_box(
		Vector3i(plate_surface.x - 8, plate_y - 5, plate_surface.z - 8),
		Vector3i(plate_surface.x + 8, plate_y + 16, plate_surface.z + 8), 4)
	_report("no_tunneling", below["count"] == 0 and on_plate["count"] > 10,
		"below_plate=%d on_plate=%d" % [below["count"], on_plate["count"]])

	# ================= test 5d: settled piles are stable (freefall flag clears) =================
	# The drop-test pile has settled by now; it must not creep afterwards.
	await _ticks(30)
	var stable_before: Dictionary = _census_box(drop_box_min, drop_box_max, 4)
	await _ticks(60)
	var stable_after: Dictionary = _census_box(drop_box_min, drop_box_max, 4)
	_report("settled_pile_is_stable",
		stable_before["count"] == stable_after["count"] \
		and stable_before["max_y"] == stable_after["max_y"],
		"before(count=%d,max_y=%d) after(count=%d,max_y=%d)" %
		[stable_before["count"], stable_before["max_y"], stable_after["count"], stable_after["max_y"]])
	# capture the settled sand pile shape for the inertia comparison below
	var sand_wide: Dictionary = _census_box(
		Vector3i(drop_surface.x - 14, drop_surface.y - 4, drop_surface.z - 14),
		Vector3i(drop_surface.x + 14, drop_surface.y + 36, drop_surface.z + 14), 4)
	var sand_core: Dictionary = _census(drop_surface, 3, 4)

	# ================= test 5e: support removal wakes the pile =================
	# Punch a hole through the tunneling-test bowl floor: the grains directly
	# above fall, and the wake cascade must pull the rest of the bowl through
	# the hole — without inertia wakes the off-hole grains would sit forever.
	# r4 sphere centered above the plate middle: opens the bowl floor (crust at
	# plate_y+4) without touching the rim tops
	world.edit_world_at(Vector3(plate_surface.x, plate_y + 2, plate_surface.z), 4.0, 0) # erase
	await _ticks(90)
	var drained: Dictionary = _census_box(
		Vector3i(plate_surface.x - 8, plate_y - 5, plate_surface.z - 8),
		Vector3i(plate_surface.x + 8, plate_y + 16, plate_surface.z + 8), 4)
	var below_after: Dictionary = _census_box(
		Vector3i(plate_surface.x - 16, plate_surface.y - 6, plate_surface.z - 16),
		Vector3i(plate_surface.x + 16, plate_y - 6, plate_surface.z + 16), 4)
	# the load-bearing assertion is the drain: without the wake cascade the
	# off-hole grains stay on the plate forever (left_on_plate stays ~27).
	# fell_below is informational only — fallen grains scatter into whatever
	# terrain the earlier tests carved up.
	_report("support_removal_wakes", drained["count"] < 12,
		"left_on_plate=%d fell_below=%d" % [drained["count"], below_after["count"]])

	# ================= test 5f: inertial resistance shapes piles =================
	# Runtime-register a dirt powder (IR 0.8 vs sand 0.1) and drop the same
	# ball; dirt must pile at least as tall and spread no wider than sand.
	var dirt := VoxelElement.new()
	dirt.element_name = "dirt"
	dirt.movement_class = VoxelElement.MOVEMENT_POWDER
	dirt.density = 2000.0
	dirt.base_color = Color(0.45, 0.3, 0.15)
	dirt.inertial_resistance = 0.8
	dirt.friction_factor = 0.6
	var dirt_id: int = world.element_set.add_element(dirt)
	_report("dirt_registered", dirt_id >= 8, "id=%d" % dirt_id)

	var dirt_origin := Vector3(31.0, 15.5, 28.5) # grid (124, ., 114)
	var dirt_hit: Vector3 = world.raycast_world(dirt_origin, DOWN_RAY, 100.0)
	var dirt_surface := Vector3i(dirt_hit)
	world.edit_world_at(Vector3(dirt_surface) + Vector3(0, 30, 0), 3.0,
		_paint_value(dirt_id, dirt.base_color))
	await _ticks(40)
	var dirt_wide: Dictionary = _census_box(
		Vector3i(dirt_surface.x - 14, dirt_surface.y - 4, dirt_surface.z - 14),
		Vector3i(dirt_surface.x + 14, dirt_surface.y + 36, dirt_surface.z + 14), dirt_id)
	var dirt_core: Dictionary = _census(dirt_surface, 3, dirt_id)
	var dirt_spread: int = dirt_wide["count"] - dirt_core["count"]
	var sand_spread: int = sand_wide["count"] - sand_core["count"]
	_report("inertia_differs",
		dirt_wide["count"] > 40 and dirt_spread < sand_spread,
		"dirt(spread=%d,core=%d,count=%d) sand(spread=%d,core=%d,count=%d)" %
		[dirt_spread, dirt_core["count"], dirt_wide["count"],
		sand_spread, sand_core["count"], sand_wide["count"]])

	# ================= test 5g: water disperses and levels out =================
	# Pour water into a rock basin: it must flatten quickly (dispersion walks
	# several cells per tick) and be strictly conserved (the basin removes the
	# run-downhill escape route that makes open-terrain water counts flaky).
	var bowl_origin := Vector3(35.5, 15.5, 28.0) # grid (142, ., 112)
	var bowl_hit: Vector3 = world.raycast_world(bowl_origin, DOWN_RAY, 100.0)
	var bowl_surface := Vector3i(bowl_hit)
	var bowl_y := bowl_surface.y + 6
	for off in [Vector3(0, 0, 0), Vector3(-4, 0, 0), Vector3(4, 0, 0), Vector3(0, 0, -4),
			Vector3(0, 0, 4), Vector3(-3.5, 0, -3.5), Vector3(3.5, 0, -3.5),
			Vector3(-3.5, 0, 3.5), Vector3(3.5, 0, 3.5)]:
		world.edit_world_at(Vector3(bowl_surface.x, bowl_y, bowl_surface.z) + off, 4.0, 1) # floor
	for off in [Vector3(-6, 3, 0), Vector3(6, 3, 0), Vector3(0, 3, -6), Vector3(0, 3, 6),
			Vector3(-4.5, 3, -4.5), Vector3(4.5, 3, -4.5), Vector3(-4.5, 3, 4.5), Vector3(4.5, 3, 4.5)]:
		world.edit_world_at(Vector3(bowl_surface.x, bowl_y, bowl_surface.z) + off, 3.0, 1) # rim
	await _ticks(2)
	# low, small pour: nothing can splash over the rim, so any voxel missing
	# from the wide census is a genuine simulation loss
	world.edit_world_at(Vector3(bowl_surface.x, bowl_y + 8, bowl_surface.z), 2.0, 3) # water ball
	await _ticks(2)
	var bowl_box_min := Vector3i(bowl_surface.x - 8, bowl_y - 5, bowl_surface.z - 8)
	var bowl_box_max := Vector3i(bowl_surface.x + 8, bowl_y + 16, bowl_surface.z + 8)
	var water_before: Dictionary = _census_box(bowl_box_min, bowl_box_max, 2)
	await _ticks(30)
	var water_after: Dictionary = _census_box(bowl_box_min, bowl_box_max, 2)
	var water_wide: Dictionary = _census_box(
		Vector3i(bowl_surface.x - 20, bowl_surface.y - 6, bowl_surface.z - 20),
		Vector3i(bowl_surface.x + 20, bowl_y + 16, bowl_surface.z + 20), 2)
	var floor_top := bowl_y + 4 # crest of the r4 floor balls
	_report("water_levels_out", water_before["count"] > 20 \
		and water_after["max_y"] - floor_top <= 2,
		"poured=%d max_y=%d floor_top=%d" %
		[water_before["count"], water_after["max_y"], floor_top])
	_report("water_mass_conserved", water_wide["count"] == water_before["count"],
		"before=%d after_bowl=%d after_wide=%d" %
		[water_before["count"], water_after["count"], water_wide["count"]])

	# ================= test 6a: explosions crater terrain and spawn sparks =================
	# The demo element set has no explosion_spark, so register one (the C++
	# pass looks it up by name, falling back to "fire").
	var spark := VoxelElement.new()
	spark.element_name = "explosion_spark"
	spark.movement_class = VoxelElement.MOVEMENT_GAS
	spark.density = 0.2
	spark.base_color = Color(1.0, 0.7, 0.25)
	spark.emission = 2.0
	spark.life = 14
	var spark_id: int = world.element_set.add_element(spark)

	var boom_origin := Vector3(33.0, 15.5, 26.5) # grid (132, ., 106)
	var boom_hit: Vector3 = world.raycast_world(boom_origin, DOWN_RAY, 100.0)
	var boom_surface := Vector3i(boom_hit)
	# box chosen to sit inside the destroy sphere (inner radius ~5 for r=10)
	var crater_box_min := Vector3i(boom_surface.x - 3, boom_surface.y - 3, boom_surface.z - 3)
	var crater_box_max := Vector3i(boom_surface.x + 3, boom_surface.y, boom_surface.z + 3)
	var rock_before: Dictionary = _census_box(crater_box_min, crater_box_max, 1)
	world.add_explosion(Vector3(boom_surface), 10.0, 5.0)
	await _ticks(2)
	var sparks: Dictionary = _census_box(
		Vector3i(boom_surface.x - 8, boom_surface.y - 5, boom_surface.z - 8),
		Vector3i(boom_surface.x + 8, boom_surface.y + 10, boom_surface.z + 8), spark_id)
	await _ticks(10)
	var rock_after: Dictionary = _census_box(crater_box_min, crater_box_max, 1)
	_report("explosion_craters", rock_before["count"] > 100 \
		and rock_after["count"] < rock_before["count"] / 2,
		"rock before=%d after=%d" % [rock_before["count"], rock_after["count"]])
	_report("explosion_sparks", sparks["count"] > 0, "sparks=%d" % sparks["count"])

	# ================= test 6b: explosion occlusion (thick rock shadows) =================
	# Sand pocket, thick rock wall, then a blast on the far side whose strength
	# (3) cannot break the wall (ER 4): the shadowed sand must survive.
	var occ_origin := Vector3(19.0, 15.5, 28.5) # grid (76, ., 114)
	var occ_hit: Vector3 = world.raycast_world(occ_origin, DOWN_RAY, 100.0)
	var occ_surface := Vector3i(occ_hit)
	world.edit_world_at(Vector3(occ_surface) + Vector3(0, 1, 0), 1.5, 2) # sand pocket
	for off in [Vector3(-4, 1, 4), Vector3(0, 1, 4), Vector3(4, 1, 4)]:
		world.edit_world_at(Vector3(occ_surface) + off, 3.0, 1) # rock wall at z+4
	await _ticks(20) # let the painted sand settle
	var shadow_box_min := Vector3i(occ_surface.x - 4, occ_surface.y - 3, occ_surface.z - 4)
	var shadow_box_max := Vector3i(occ_surface.x + 4, occ_surface.y + 4, occ_surface.z + 2)
	var wall_box_min := Vector3i(occ_surface.x - 6, occ_surface.y - 1, occ_surface.z + 3)
	var wall_box_max := Vector3i(occ_surface.x + 6, occ_surface.y + 3, occ_surface.z + 5)
	var shadow_before: Dictionary = _census_box(shadow_box_min, shadow_box_max, 4)
	var wall_before: Dictionary = _census_box(wall_box_min, wall_box_max, 1)
	world.add_explosion(Vector3(occ_surface) + Vector3(0, 2, 8), 10.0, 3.0)
	await _ticks(6)
	var shadow_after: Dictionary = _census_box(shadow_box_min, shadow_box_max, 4)
	var wall_after: Dictionary = _census_box(wall_box_min, wall_box_max, 1)
	_report("explosion_occlusion", shadow_before["count"] > 5 \
		and shadow_after["count"] >= shadow_before["count"] \
		and wall_after["count"] == wall_before["count"],
		"shadowed sand before=%d after=%d, wall before=%d after=%d" %
		[shadow_before["count"], shadow_after["count"], wall_before["count"], wall_after["count"]])

	# ================= test 6c: zero-resistance water vaporizes =================
	# The bowl still holds the leveled water; a weak blast (strength 3) cannot
	# damage the rock bowl (ER 4) but obliterates the ER-0 water inside it.
	var bowl_water_before: Dictionary = _census_box(bowl_box_min, bowl_box_max, 2)
	world.add_explosion(Vector3(bowl_surface.x, floor_top + 1, bowl_surface.z), 8.0, 3.0)
	await _ticks(6)
	var bowl_water_after: Dictionary = _census_box(bowl_box_min, bowl_box_max, 2)
	_report("water_vaporizes", bowl_water_before["count"] > 20 \
		and bowl_water_after["count"] < bowl_water_before["count"] / 3,
		"water before=%d after=%d" % [bowl_water_before["count"], bowl_water_after["count"]])

	# ================= test 6d: explosions throw particles =================
	# Blast UNDER the settled dirt pile: the pile sits in the throw ring, so
	# its grains become ballistic particles with upward velocity. Slides and
	# falls only ever lose altitude — any dirt appearing above the old pile
	# top can only be a thrown particle. Also guards against duplication.
	var wide_dirt_min := Vector3i(dirt_surface.x - 24, dirt_surface.y - 6, dirt_surface.z - 24)
	var wide_dirt_max := Vector3i(dirt_surface.x + 24, dirt_surface.y + 30, dirt_surface.z + 24)
	var wide_before: Dictionary = _census_box(wide_dirt_min, wide_dirt_max, dirt_id)
	var pile_top: int = wide_before["max_y"]
	world.add_explosion(Vector3(dirt_surface.x, dirt_surface.y - 4, dirt_surface.z), 10.0, 5.0)
	await _ticks(3)
	var launched: Dictionary = _census_box(wide_dirt_min, wide_dirt_max, dirt_id)
	await _ticks(12)
	var wide_after: Dictionary = _census_box(wide_dirt_min, wide_dirt_max, dirt_id)
	_report("explosion_throws_particles", launched["max_y"] >= pile_top + 2,
		"pile_top=%d max_y_at_3_ticks=%d" % [pile_top, launched["max_y"]])
	_report("particles_no_duplication", wide_after["count"] <= wide_before["count"],
		"wide before=%d after=%d" % [wide_before["count"], wide_after["count"]])

	# ================= test 5b: sand mass is conserved (dynamics plumbing) =================
	# The tripwire for every CAS/double-buffer bug: no grain may duplicate or
	# vanish while settling. Wide census box so rolling grains stay counted.
	var mc_origin := Vector3(38.5, 15.5, 26.0)
	var mc_hit: Vector3 = world.raycast_world(mc_origin, DOWN_RAY, 100.0)
	var mc_surface := Vector3i(mc_hit)
	world.edit_world(mc_origin, DOWN_RAY, 2.5, 100.0, 2) # legacy value 2 = sand
	await _ticks(2)
	var mc_before: Dictionary = _census(mc_surface, 10, 4)
	await _ticks(60)
	var mc_after: Dictionary = _census(mc_surface, 10, 4)
	_report("sand_mass_conserved", mc_before["count"] > 10 and mc_after["count"] == mc_before["count"],
		"before=%d after=%d" % [mc_before["count"], mc_after["count"]])
#
	# ================= test 6: ice melts via heat diffusion (static, no flow confound) =================
	var ice_id: int = world.element_set.find_element_id("ice")
	var ice_origin := Vector3(29.5, 15.5, 26.5) # grid (118, ., 106)
	var ice_hit: Vector3 = world.raycast_world(ice_origin, DOWN_RAY, 100.0)
	var ice_surface := Vector3i(ice_hit)
	world.edit_world(ice_origin, DOWN_RAY, 2.5, 100.0, _paint_value(ice_id, Color(0.65, 0.8, 0.95)))
	await _ticks(2)
	var ice_start: Dictionary = _census(ice_surface, 5, ice_id)
	await _ticks(300) # ambient 293K air warms 260K ice past its 274K melting point
	var ice_end: Dictionary = _census(ice_surface, 5, ice_id)
	_report("ice_melts", ice_start["count"] > 10 and ice_end["count"] < ice_start["count"],
		"ice before=%d after=%d" % [ice_start["count"], ice_end["count"]])

	# ================= test 7: vine grows via the Tier-4 custom pass =================
	var vine_origin := Vector3(37.8, 15.5, 27.8) # grid (151, ., 111)
	var vine_hit: Vector3 = world.raycast_world(vine_origin, DOWN_RAY, 100.0)
	var vine_surface := Vector3i(vine_hit)
	world.edit_world(vine_origin, DOWN_RAY, 1.5, 100.0, 5) # legacy value 5 = vine (energy 15)
	await _ticks(2)
	var vine_before: Dictionary = _census(vine_surface + Vector3i(0, 2, 0), 5, 5)
	await _ticks(150)
	var vine_after: Dictionary = _census(vine_surface + Vector3i(0, 2, 0), 5, 5)
	_report("vine_grows_custom_pass", vine_before["count"] > 0 and vine_after["count"] > vine_before["count"],
		"vine before=%d after=%d hit=%s" % [vine_before["count"], vine_after["count"], str(vine_hit)])

	# ================= test 8: gunpowder chain-detonates on fire =================
	var gp_id: int = world.element_set.find_element_id("gunpowder")
	var fire_id: int = world.element_set.find_element_id("fire")
	var gp_origin := Vector3(38.0, 15.5, 29.0) # grid (152, ., 116)
	var gp_hit: Vector3 = world.raycast_world(gp_origin, DOWN_RAY, 100.0)
	var gp_surface := Vector3i(gp_hit)
	world.edit_world(gp_origin, DOWN_RAY, 2.5, 100.0, _paint_value(gp_id, Color(0.2, 0.2, 0.22)))
	await _ticks(2)
	var gp_before: Dictionary = _census(gp_surface, 5, gp_id)
	world.edit_world(gp_origin + Vector3(0, 0.5, 0), DOWN_RAY, 1.5, 100.0, _paint_value(fire_id, Color(1, 0.45, 0.08)))
	await _ticks(60)
	var gp_after: Dictionary = _census(gp_surface, 5, gp_id)
	_report("gunpowder_detonates", gp_before["count"] > 10 and gp_after["count"] < gp_before["count"] / 2,
		"gunpowder before=%d after=%d" % [gp_before["count"], gp_after["count"]])

	## ================= test 9: element editor panel (F toggles, apply registers) =================
	#var panel: Control = null
	#for node in get_tree().get_nodes_in_group("ca_ui_blocking"):
		#if node is PanelContainer:
			#panel = node
	#if panel == null:
		#_report("editor_panel_applies", false, "panel not found")
	#else:
		#var f_key := InputEventKey.new()
		#f_key.keycode = KEY_F
		#f_key.pressed = true
		#Input.parse_input_event(f_key)
		#await _ticks(2)
		#var visible_ok: bool = panel.visible
		#panel._name_edit.text = "crystal"
		#panel._class_picker.select(0) # static
		#panel._color_picker.color = Color(0.8, 0.4, 0.9)
		#panel._emission.value = 1.0
		#panel._on_apply()
		#var crystal_id: int = world.element_set.find_element_id("crystal")
		#_report("editor_panel_applies", visible_ok and crystal_id >= 8,
			#"visible=%s id=%d" % [visible_ok, crystal_id])

	# ================= test 10: texture projection stamps elements =================
	# A white bar on a transparent background, projected straight down as sand:
	# opaque texels must become sand voxels on the terrain surface.
	var proj_img := Image.create(64, 32, false, Image.FORMAT_RGBA8)
	proj_img.fill(Color(0, 0, 0, 0))
	proj_img.fill_rect(Rect2i(8, 8, 48, 16), Color(1, 1, 1, 1))
	var rd := RenderingServer.get_rendering_device()
	var fmt := RDTextureFormat.new()
	fmt.width = 64
	fmt.height = 32
	fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var proj_tex: RID = rd.texture_create(fmt, RDTextureView.new(), [proj_img.get_data()])

	var proj_origin := Vector3(39.0, 15.5, 28.5)
	var proj_hit: Vector3 = world.raycast_world(proj_origin, DOWN_RAY, 100.0)
	var proj_surface := Vector3i(proj_hit)
	var proj_xform := Transform3D(Basis.looking_at(DOWN_RAY.normalized(), Vector3(0, 0, 1)), proj_origin)
	var proj_vp: Projection = Projection.create_perspective(25.0, 2.0, 0.05, 100.0, false) \
		* Projection(proj_xform.affine_inverse())
	world.project_texture(proj_tex, Vector2i(64, 32), proj_vp.inverse(), proj_origin,
		2, Color(1.0, 0.6, 0.2), 0.5, 100.0, false) # legacy value 2 = sand, orange tint
	await _ticks(2)
	var projected: Dictionary = _census(proj_surface, 5, 4) # type 4 = sand
	var proj_color_ok := false
	if projected["count"] > 0:
		# find one projected voxel and check the tint survived (orange: r > b)
		for x in range(proj_surface.x - 5, proj_surface.x + 6):
			for z in range(proj_surface.z - 5, proj_surface.z + 6):
				var v: Dictionary = world.get_voxel_at(Vector3i(x, proj_surface.y, z))
				if int(v["type"]) == 4:
					var c: Color = v["color"]
					proj_color_ok = c.r > c.b
					break
			if proj_color_ok:
				break
	_report("texture_projection_stamps_sand", projected["count"] > 20,
		"sand=%d" % projected["count"])
	_report("texture_projection_tint", proj_color_ok, "")

	# ================= test 11: parallel-ray (oblique/screen-space) projection =================
	# Same white bar, projected straight down with parallel rays — the path used
	# for screen-space projection from the oblique VoxelCamera.
	var par_origin := Vector3(17.0, 15.5, 29.0)
	var par_hit: Vector3 = world.raycast_world(par_origin, DOWN_RAY, 100.0)
	var par_surface := Vector3i(par_hit)
	world.project_texture_parallel(proj_tex, Vector2i(64, 32), par_origin,
		Vector3(2, 0, 0), Vector3(0, 0, 2), DOWN_RAY.normalized(),
		2, Color(1.0, 0.6, 0.2), 0.5, 100.0, false) # sand, orange tint
	await _ticks(2)
	var par_projected: Dictionary = _census(par_surface, 5, 4)
	_report("texture_projection_parallel", par_projected["count"] > 20,
		"sand=%d" % par_projected["count"])
	rd.free_rid(proj_tex)

	await _ticks(2)
	var img2: Image = get_viewport().get_texture().get_image()
	img2.save_png("user://ca_test_final.png")
	print("CA-TEST final screenshot: ", ProjectSettings.globalize_path("user://ca_test_final.png"))

	_finish()
