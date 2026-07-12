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
func _census(center: Vector3i, half: int, type_id: int) -> Dictionary:
	var count := 0
	var max_y := -1
	for x in range(center.x - half, center.x + half + 1):
		for y in range(center.y - half, center.y + half + 1):
			for z in range(center.z - half, center.z + half + 1):
				var v: Dictionary = world.get_voxel_at(Vector3i(x, y, z))
				if int(v["type"]) == type_id:
					count += 1
					max_y = max(max_y, y)
	return {"count": count, "max_y": max_y}


func _run_tests() -> void:
	await _ticks(20) # let the world initialize and settle

	# ---- debug: coarse census of the whole grid by element type ----
	var type_counts := {}
	for x in range(8, 256, 24):
		for y in range(0, 64, 8):
			for z in range(8, 64, 12):
				var t: int = int(world.get_voxel_at(Vector3i(x, y, z))["type"])
				type_counts[t] = int(type_counts.get(t, 0)) + 1
	print("CA-TEST world census (coarse): ", type_counts)
	await _ticks(2)
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png("user://ca_test_view.png")
	print("CA-TEST screenshot saved to ", ProjectSettings.globalize_path("user://ca_test_view.png"))

	# ---- find a terrain surface point via a downward raycast (world space) ----
	var probe_origin := Vector3(20.0, 15.5, 8.0)
	var hit: Vector3 = world.raycast_world(probe_origin, DOWN_RAY, 100.0)
	var surface := Vector3i(hit)
	var ok_hit: bool = hit.y > 0.0 and hit.y < 64.0
	_report("terrain_raycast", ok_hit, str(hit))
	if not ok_hit:
		_finish()
		return

	# ================= test 1: painted water exists and moves =================
	#world.edit_world(probe_origin, DOWN_RAY, 3.0, 100.0, 3) # legacy value 3 = water
	#await _ticks(2)
	#var before: Dictionary = _census(surface, 5, 2) # type 2 = water
	#_report("water_painted", before["count"] > 10, "count=%d" % before["count"])
#
	#await _ticks(60)
	#var after: Dictionary = _census(surface, 5, 2)
	## evidence of movement: the sphere cap collapsed, or the water flowed
	## downhill out of the box entirely (void borders eat it at the world edge)
	#var ok_flow: bool = after["count"] == 0 or after["max_y"] < before["max_y"] \
		#or after["count"] < before["count"]
	#_report("water_flows", ok_flow,
		#"before(count=%d,max_y=%d) after(count=%d,max_y=%d)" %
		#[before["count"], before["max_y"], after["count"], after["max_y"]])
#
	## ================= test 2: lava + water -> solid + steam =================
	## fresh site: pour water and immediately drop lava on it, then look for steam
	#var quench_origin := Vector3(27.0, 15.5, 8.0)
	#var quench_hit: Vector3 = world.raycast_world(quench_origin, DOWN_RAY, 100.0)
	#var quench_surface := Vector3i(quench_hit)
	#world.edit_world(quench_origin, DOWN_RAY, 3.0, 100.0, 3) # water
	#await _ticks(2)
	#world.edit_world(quench_origin + Vector3(0, 0.5, 0), DOWN_RAY, 2.0, 100.0, 4) # lava on top
	#await _ticks(20)
	#var steam: Dictionary = _census(quench_surface + Vector3i(0, 4, 0), 6, 8) # type 8 = steam
	#_report("quench_makes_steam", steam["count"] > 0, "steam=%d" % steam["count"])
#
	## ================= test 3: runtime-defined acid dissolves terrain =================
	#var acid := VoxelElement.new()
	#acid.element_name = "acid"
	#acid.movement_class = VoxelElement.MOVEMENT_LIQUID
	#acid.density = 1100.0
	#acid.base_color = Color(0.6, 0.9, 0.2)
	#acid.emission = 0.4
	#acid.add_reaction("solid", "", "air", 0.4) # corrode rock away
	#var acid_id: int = world.element_set.add_element(acid) # auto re-uploads tables
	#_report("acid_registered", acid_id >= 8, "id=%d" % acid_id)
#
	#var acid_origin := Vector3(44.0, 15.5, 8.0) # fresh terrain away from the water tests
	#var acid_hit: Vector3 = world.raycast_world(acid_origin, DOWN_RAY, 100.0)
	#var acid_surface := Vector3i(acid_hit)
	#var rock_before: Dictionary = _census(acid_surface - Vector3i(0, 2, 0), 3, 1) # type 1 = solid
	#world.edit_world(acid_origin, DOWN_RAY, 2.5, 100.0, _paint_value(acid_id, acid.base_color))
	#await _ticks(2)
	#var acid_present: Dictionary = _census(acid_surface, 4, acid_id)
	#_report("acid_painted", acid_present["count"] > 5, "count=%d" % acid_present["count"])
#
	#await _ticks(120)
	#var rock_after: Dictionary = _census(acid_surface - Vector3i(0, 2, 0), 3, 1)
	#_report("acid_dissolves_rock", rock_after["count"] < rock_before["count"],
		#"rock before=%d after=%d" % [rock_before["count"], rock_after["count"]])
#
	## ================= test 4: runtime cloner via behavior ops =================
	#var cloner := VoxelElement.new()
	#cloner.element_name = "cloner"
	#cloner.movement_class = VoxelElement.MOVEMENT_STATIC
	#cloner.base_color = Color(0.9, 0.5, 0.9)
	#cloner.add_behavior_op(VoxelBehaviorOp.OP_CREATE, Vector3i(0, 1, 0), "water", "", 0.5,
		#VoxelBehaviorOp.SYMMETRY_NONE)
	#var cloner_id: int = world.element_set.add_element(cloner)
	#_report("cloner_registered", cloner_id >= 8, "id=%d" % cloner_id)
#
	#var cloner_origin := Vector3(54.0, 15.5, 8.0)
	#var cloner_hit: Vector3 = world.raycast_world(cloner_origin, DOWN_RAY, 100.0)
	#var cloner_surface := Vector3i(cloner_hit)
	#world.edit_world(cloner_origin, DOWN_RAY, 1.5, 100.0, _paint_value(cloner_id, cloner.base_color))
	#await _ticks(60)
	#var made_water: Dictionary = _census(cloner_surface + Vector3i(0, 2, 0), 4, 2)
	#_report("cloner_emits_water", made_water["count"] > 0, "water=%d" % made_water["count"])
#
	## ================= test 5: sand (powder class) piles up =================
	#var sand_origin := Vector3(34.0, 15.5, 12.0)
	#var sand_hit: Vector3 = world.raycast_world(sand_origin, DOWN_RAY, 100.0)
	#var sand_surface := Vector3i(sand_hit)
	#world.edit_world(sand_origin, DOWN_RAY, 2.5, 100.0, 2) # legacy value 2 = sand
	#await _ticks(2)
	#var sand_before: Dictionary = _census(sand_surface, 5, 4) # type 4 = sand
	#await _ticks(90)
	#var sand_after: Dictionary = _census(sand_surface, 5, 4)
	#_report("sand_falls", sand_before["count"] > 10 and sand_after["count"] > 0 \
		#and sand_after["max_y"] <= sand_before["max_y"],
		#"before(count=%d,max_y=%d) after(count=%d,max_y=%d)" %
		#[sand_before["count"], sand_before["max_y"], sand_after["count"], sand_after["max_y"]])
#
	## ================= test 6: ice melts via heat diffusion (static, no flow confound) =================
	#var ice_origin := Vector3(10.0, 15.5, 12.0)
	#var ice_hit: Vector3 = world.raycast_world(ice_origin, DOWN_RAY, 100.0)
	#var ice_surface := Vector3i(ice_hit)
	#world.edit_world(ice_origin, DOWN_RAY, 2.5, 100.0, _paint_value(9, Color(0.65, 0.8, 0.95))) # ice, id 9
	#await _ticks(2)
	#var ice_start: Dictionary = _census(ice_surface, 5, 9)
	#await _ticks(300) # ambient 293K air warms 260K ice past its 274K melting point
	#var ice_end: Dictionary = _census(ice_surface, 5, 9)
	#_report("ice_melts", ice_start["count"] > 10 and ice_end["count"] < ice_start["count"],
		#"ice before=%d after=%d" % [ice_start["count"], ice_end["count"]])
#
	## ================= test 7: vine grows via the Tier-4 custom pass =================
	#var vine_origin := Vector3(48.0, 15.5, 12.0)
	#var vine_hit: Vector3 = world.raycast_world(vine_origin, DOWN_RAY, 100.0)
	#var vine_surface := Vector3i(vine_hit)
	#world.edit_world(vine_origin, DOWN_RAY, 1.5, 100.0, 5) # legacy value 5 = vine (energy 15)
	#await _ticks(2)
	#var vine_before: Dictionary = _census(vine_surface + Vector3i(0, 2, 0), 5, 5)
	#await _ticks(150)
	#var vine_after: Dictionary = _census(vine_surface + Vector3i(0, 2, 0), 5, 5)
	#_report("vine_grows_custom_pass", vine_before["count"] > 0 and vine_after["count"] > vine_before["count"],
		#"vine before=%d after=%d" % [vine_before["count"], vine_after["count"]])
#
	## ================= test 8: gunpowder chain-detonates on fire =================
	#var gp_origin := Vector3(58.0, 15.5, 12.0)
	#var gp_hit: Vector3 = world.raycast_world(gp_origin, DOWN_RAY, 100.0)
	#var gp_surface := Vector3i(gp_hit)
	#world.edit_world(gp_origin, DOWN_RAY, 2.5, 100.0, _paint_value(17, Color(0.2, 0.2, 0.22))) # gunpowder
	#await _ticks(2)
	#var gp_before: Dictionary = _census(gp_surface, 5, 17)
	#world.edit_world(gp_origin + Vector3(0, 0.5, 0), DOWN_RAY, 1.5, 100.0, _paint_value(10, Color(1, 0.45, 0.08))) # fire
	#await _ticks(60)
	#var gp_after: Dictionary = _census(gp_surface, 5, 17)
	#_report("gunpowder_detonates", gp_before["count"] > 10 and gp_after["count"] < gp_before["count"] / 2,
		#"gunpowder before=%d after=%d" % [gp_before["count"], gp_after["count"]])
#
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

	var proj_origin := Vector3(40.0, 15.5, 16.0)
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
	var par_origin := Vector3(16.0, 15.5, 16.0)
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
