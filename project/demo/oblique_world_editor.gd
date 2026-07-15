extends Node3D
## Cursor-based voxel drawing for the oblique VoxelCamera.
##
## Translation of world_editor.gd's drawing functions: instead of casting one
## ray from the camera crosshair, rays are built under the mouse cursor using
## the same parallel-ray construction as voxel_renderer_oblique.glsl — origins
## spread across a view plane through the camera position, all rays sharing
## one sheared direction. Requires a visible mouse cursor.
##
## Brushes (cycle with `change_brush`):
##   PLACE      left = paint element, right = erase
##   SMOOTH     left = smooth surface
##   EXPLOSION  left = detonate at cursor (craters + sparks)
##   PARTICLES  hold left = fountain of spark particles; drag to aim
##   Y_LEVEL    left = paint at a fixed grid y-plane (up/down arrows move it),
##              right = erase; ignores the surface, so you can paint midair
##   STAMP      shows a texture preview under the cursor; left = stamp it in

@export var world: VoxelWorld
@export var voxel_camera: Node3D  # VoxelCamera

@export var selected_material: int = 1
@export var radius: int = 4
enum Brush { PLACE, SMOOTH, EXPLOSION, PARTICLES, Y_LEVEL, STAMP }
@export var brush_mode: Brush = Brush.PLACE

@export_group("Explosion brush")
@export var explosion_strength: float = 5.0

@export_group("Particle brush")
## Element sprayed by the fountain (must be a dynamic element — powder/liquid/
## gas — to actually fly). Falls back to "fire", then to the currently selected
## element, if the name isn't in the world's element set.
@export var particle_element_name: String = "explosion_spark"
## Particles spawned per emission tick.
@export var particle_count: int = 6
## Horizontal launch speed toward the drag direction (grid cells per tick).
@export var particle_speed: float = 3.0
## Upward launch speed (grid cells per tick).
@export var particle_up_speed: float = 4.0
## Radius of each particle blob.
@export var particle_blob_radius: float = 1.0
## Random spread added to launch position (grid units) and velocity (cells/tick).
@export var particle_spread: float = 1.0

@export_group("Y-level brush")
## Grid y-plane the brush paints on. Adjust in-game with the up/down arrows.
@export var paint_y: int = 32

@export_group("Stamp brush")
## Texture stamped into the world. Opaque texels become voxels of the selected
## element; transparent texels are skipped.
@export var stamp_texture: Texture2D
## Stamp footprint width on screen, in pixels (height follows texture aspect).
@export var stamp_size_px: float = 160.0
## Multiplied into the texture color before it becomes voxel color.
@export var stamp_tint: Color = Color.WHITE
@export_range(0.0, 1.0) var stamp_alpha_threshold: float = 0.5
## false = convert the surface voxel (paint); true = spawn into the air in
## front of the surface (good for sand/water so it doesn't eat walls).
@export var stamp_place_on_surface: bool = false

@export_group("Oblique projection — must match voxel_renderer_oblique.glsl")
@export var oblique_angle_degrees: float = 270.0
@export var oblique_strength: float = 1.0
@export var oblique_focus_distance: float = 60.0
@export var oblique_pullback: float = 0.0

const RAY_DISTANCE := 1000.0
const BRICK_SIZE := 8

# legacy hotbar-slot mapping, kept for compatibility with set_selected_material
const MATERIAL_TO_VOXEL_TYPE = {1: 1, 2: 4, 3: 2, 4: 3, 5: 5}
const MATERIAL_DEFAULT_COLORS = {
	1: Color(0.24, 0.25, 0.32),  # Rock (gray)
	2: Color(0.91, 0.82, 0.52),  # Sand (tan)
	3: Color(0.2, 0.4, 0.8),     # Water (blue)
	4: Color(0.9, 0.3, 0.1),     # Lava (orange-red)
	5: Color(0.2, 0.7, 0.15),    # Vine (green)
}

var selected_type: int = 1  # element id painted by left click
var selected_color: Color = MATERIAL_DEFAULT_COLORS[1]
var cooldown := 0.0
var _emit_cooldown := 0.0

# 2D overlay showing the stamp texture under the cursor (the oblique renderer
# doesn't draw normal 3D meshes, so the preview has to live on the output rect).
var _stamp_preview: TextureRect


## Preferred selection API: paint an element id from the world's element set
## (used by the dynamic palette; colors default to the element's base color).
func select_element(type_id: int, color: Color) -> void:
	selected_type = type_id
	selected_color = color


func set_selected_material(value: int) -> void:
	selected_material = value
	selected_type = MATERIAL_TO_VOXEL_TYPE.get(value, 1)
	if MATERIAL_DEFAULT_COLORS.has(value):
		selected_color = MATERIAL_DEFAULT_COLORS[value]


func compress_color16(col: Color) -> int:
	var h := int(col.h * 127.0)
	var s := int(col.s * 15.0)
	var v := int(col.v * 31.0)
	return (h << 9) | (s << 5) | v


## Element encoding shared with edit_world / edit_world_at.
func _encode_value(type_id: int, color: Color) -> int:
	if type_id == 0:
		return 0  # air
	# Encoding: (voxel_type << 24) | (1 << 16) | color16
	return (type_id << 24) | (1 << 16) | compress_color16(color)


func _get_edit_value() -> int:
	return _encode_value(selected_type, selected_color)


## true while the cursor is over blocking UI (palette, element editor)
func _ui_blocked() -> bool:
	var mouse := get_viewport().get_mouse_position()
	for node in get_tree().get_nodes_in_group("ca_ui_blocking"):
		if node is Control and node.visible and node.get_global_rect().has_point(mouse):
			return true
	return false


## Ray under the mouse cursor in the oblique projection.
## Returns {} when the cursor is outside the rendered view. The dictionary also
## carries the view-plane basis (right/up/forward) and half extents so brushes
## can build screen-aligned projections without recomputing them.
func _mouse_ray() -> Dictionary:
	var rect: TextureRect = voxel_camera.output_texture
	if rect == null or rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return {}
	var uv := rect.get_local_mouse_position() / rect.size
	if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
		return {}

	var ndc := uv * 2.0 - Vector2.ONE
	ndc.y = -ndc.y

	var cam_basis := voxel_camera.global_transform.basis
	var forward: Vector3 = -cam_basis.z
	var right: Vector3 = cam_basis.x
	var up: Vector3 = cam_basis.y

	# Aspect of the render target (window size at camera init), not the rect —
	# the rect may stretch the texture.
	var render_tex = voxel_camera.get_render_texture()
	var aspect := 1.0
	if render_tex != null and render_tex.get_height() > 0:
		aspect = float(render_tex.get_width()) / float(render_tex.get_height())

	var half_height := tan(deg_to_rad(voxel_camera.fov) * 0.5) * oblique_focus_distance
	var half_width := half_height * aspect

	var origin: Vector3 = voxel_camera.global_position \
		+ right * (ndc.x * half_width) \
		+ up * (ndc.y * half_height) \
		- forward * oblique_pullback

	var oblique_angle := deg_to_rad(oblique_angle_degrees)
	var shear := Vector2(cos(oblique_angle), sin(oblique_angle)) * oblique_strength
	var dir := (forward - right * shear.x - up * shear.y).normalized()

	return {
		"origin": origin, "dir": dir,
		"right": right, "up": up, "forward": forward,
		"half_width": half_width, "half_height": half_height,
		"rect": rect,
	}


## Grid-space height of the world (voxels along y).
func _grid_height() -> int:
	return world.get_brick_map_size().y * BRICK_SIZE


## Intersect the world-space cursor ray with a horizontal grid-space plane at
## `grid_y`. Returns {} when the ray is parallel to the plane or points away.
func _grid_plane_hit(ray: Dictionary, grid_y: float) -> Dictionary:
	var s := world.get_scale()
	# world -> grid is a uniform divide by scale (VoxelWorld sits at the origin),
	# so directions keep their orientation and only origins convert.
	var g_origin: Vector3 = ray.origin / s
	var g_dir: Vector3 = ray.dir
	if absf(g_dir.y) < 1e-5:
		return {}
	var t := (grid_y - g_origin.y) / g_dir.y
	if t <= 0.0:
		return {}
	return {"pos": g_origin + g_dir * t}


## Resolve the particle element id + color once per emission.
func _particle_value() -> int:
	var element_set := world.get_element_set()
	if element_set != null:
		var id := element_set.find_element_id(particle_element_name)
		if id < 0:
			id = element_set.find_element_id("fire")
		if id > 0:
			var elem = element_set.get_element(id)
			var col: Color = elem.base_color if elem != null else selected_color
			return _encode_value(id, col)
	return _get_edit_value()


func _process(delta: float) -> void:
	cooldown -= delta
	_emit_cooldown -= delta

	if Input.is_action_just_pressed("change_brush"):
		brush_mode = ((brush_mode + 1) % Brush.size()) as Brush
		print("brush mode: " + Brush.keys()[brush_mode])

	if Input.is_action_pressed("scroll_down"):
		radius = clampi(radius - 2, 1, 62)
	if Input.is_action_pressed("scroll_up"):
		if radius <= 62:
			radius += 2

	# Y-level brush: arrow keys scrub the paint plane up/down.
	if brush_mode == Brush.Y_LEVEL:
		if Input.is_action_just_pressed("up"):
			paint_y = clampi(paint_y + 1, 0, _grid_height() - 1)
		if Input.is_action_just_pressed("down"):
			paint_y = clampi(paint_y - 1, 0, _grid_height() - 1)

	var ray := _mouse_ray()
	if ray.is_empty() or _ui_blocked():
		world.clear_brush_preview()
		_set_stamp_preview_visible(false)
		return

	match brush_mode:
		Brush.PLACE:
			_update_surface_preview(ray)
			_process_place(ray)
		Brush.SMOOTH:
			_update_surface_preview(ray)
			_process_smooth(ray)
		Brush.EXPLOSION:
			_update_surface_preview(ray)
			_process_explosion(ray)
		Brush.PARTICLES:
			_update_surface_preview(ray)
			_process_particles(ray)
		Brush.Y_LEVEL:
			_process_y_level(ray)
		Brush.STAMP:
			_process_stamp(ray)


## Sphere preview at the surface hit under the cursor.
func _update_surface_preview(ray: Dictionary) -> void:
	var hit_pos: Vector3 = world.raycast_world(ray.origin, ray.dir, RAY_DISTANCE)
	if hit_pos.x >= 0:
		world.set_brush_preview(hit_pos, radius)
	else:
		world.clear_brush_preview()


func _process_place(ray: Dictionary) -> void:
	if Input.is_action_pressed("left_click") and cooldown < 0.01:
		world.edit_world(ray.origin, ray.dir, radius, RAY_DISTANCE, _get_edit_value())
		cooldown = 0.1
	if Input.is_action_pressed("right_click") and cooldown < 0.01:
		world.edit_world(ray.origin, ray.dir, radius, RAY_DISTANCE, 0)
		cooldown = 0.1


func _process_smooth(ray: Dictionary) -> void:
	if Input.is_action_pressed("left_click") and cooldown < 0.01:
		world.edit_world_smooth(ray.origin, ray.dir, radius, RAY_DISTANCE)
		cooldown = 0.1


func _process_explosion(ray: Dictionary) -> void:
	if Input.is_action_pressed("left_click") and cooldown < 0.01:
		# add_explosion wants a grid-space center, which is exactly what the
		# raycast returns; the old code passed world-space camera coords.
		var hit_pos: Vector3 = world.raycast_world(ray.origin, ray.dir, RAY_DISTANCE)
		if hit_pos.x >= 0:
			world.add_explosion(hit_pos, float(radius), explosion_strength)
			cooldown = 0.2


## Fountain of spark particles launched from the surface under the initial
## click, shooting upward and toward wherever the cursor is dragged. Uses the
## C++ velocity-spawn path (edit_world_at_velocity): each blob becomes a real
## ballistic particle that flies along its initial velocity and arcs under
## gravity, instead of a static blob that only rises.
func _process_particles(ray: Dictionary) -> void:
	if not Input.is_action_pressed("left_click"):
		return

	var launch: Vector3 = world.raycast_world(ray.origin, ray.dir, RAY_DISTANCE)
	if launch.x < 0:
		return  # nothing under the cursor to launch from

	if _emit_cooldown > 0.0:
		return
	_emit_cooldown = 0.03

	# Horizontal aim toward the cursor, projected onto the launch's y-plane.
	var aim := Vector3.ZERO
	var target := _grid_plane_hit(ray, launch.y)
	if not target.is_empty():
		var flat: Vector3 = target.pos - launch
		flat.y = 0.0
		if flat.length() > 0.001:
			aim = flat.normalized()

	var value := _particle_value()
	var base_vel := aim * particle_speed + Vector3.UP * particle_up_speed
	# lift the spawn point slightly so particles don't start buried in the surface
	var origin := launch + Vector3.UP * 2.0
	for i in range(particle_count):
		var jitter_pos := Vector3(
			randf_range(-particle_spread, particle_spread),
			randf_range(0.0, particle_spread),
			randf_range(-particle_spread, particle_spread))
		var jitter_vel := Vector3(
			randf_range(-particle_spread, particle_spread),
			randf_range(-particle_spread, particle_spread),
			randf_range(-particle_spread, particle_spread))
		world.edit_world_at_velocity(origin + jitter_pos, particle_blob_radius,
				value, base_vel + jitter_vel)


## Paint on a fixed grid y-plane regardless of the surface, so you can draw in
## midair. Left paints the selected element, right erases.
func _process_y_level(ray: Dictionary) -> void:
	var plane := _grid_plane_hit(ray, float(paint_y))
	if plane.is_empty():
		world.clear_brush_preview()
		return

	var pos: Vector3 = plane.pos
	world.set_brush_preview(pos, radius)

	if Input.is_action_pressed("left_click") and cooldown < 0.01:
		world.edit_world_at(pos, float(radius), _get_edit_value())
		cooldown = 0.1
	if Input.is_action_pressed("right_click") and cooldown < 0.01:
		world.edit_world_at(pos, float(radius), 0)
		cooldown = 0.1


## Show a live preview of the stamp texture under the cursor and project it into
## the world on click. The preview rectangle and the projected footprint share
## the same screen->view-plane mapping, so what you see is what lands.
func _process_stamp(ray: Dictionary) -> void:
	world.clear_brush_preview()
	if stamp_texture == null:
		_set_stamp_preview_visible(false)
		return

	var tex_size := stamp_texture.get_size()
	var aspect := tex_size.x / tex_size.y if tex_size.y > 0.0 else 1.0
	var px := stamp_size_px
	var py := stamp_size_px / aspect

	_update_stamp_preview(ray, px, py)

	if Input.is_action_pressed("left_click") and cooldown < 0.01:
		_stamp(ray, px, py)
		cooldown = 0.2


func _stamp(ray: Dictionary, px: float, py: float) -> void:
	var rd_rid := RenderingServer.texture_get_rd_texture(stamp_texture.get_rid())
	if not rd_rid.is_valid():
		return

	var rect: TextureRect = ray.rect
	# ndc spans [-1,1] over the stamp, so the half-extents are the world offset
	# for half the stamp's pixel span (same mapping _mouse_ray uses per axis).
	var right_extent: Vector3 = ray.right * (px / rect.size.x) * ray.half_width
	var up_extent: Vector3 = ray.up * (py / rect.size.y) * ray.half_height

	world.project_texture_parallel(
		rd_rid, Vector2i(stamp_texture.get_size()),
		ray.origin, right_extent, up_extent, ray.dir,
		_get_edit_value(), stamp_tint, stamp_alpha_threshold,
		RAY_DISTANCE, stamp_place_on_surface)


func _ensure_stamp_preview() -> void:
	if _stamp_preview != null and is_instance_valid(_stamp_preview):
		return
	_stamp_preview = TextureRect.new()
	_stamp_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stamp_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_stamp_preview.stretch_mode = TextureRect.STRETCH_SCALE
	_stamp_preview.modulate = Color(1, 1, 1, 0.5)
	_stamp_preview.visible = false
	var rect: TextureRect = voxel_camera.output_texture
	rect.add_child(_stamp_preview)


func _update_stamp_preview(ray: Dictionary, px: float, py: float) -> void:
	_ensure_stamp_preview()
	_stamp_preview.texture = stamp_texture
	_stamp_preview.modulate = Color(stamp_tint.r, stamp_tint.g, stamp_tint.b, 0.5)
	var rect: TextureRect = ray.rect
	var mouse := rect.get_local_mouse_position()
	_stamp_preview.size = Vector2(px, py)
	_stamp_preview.position = mouse - Vector2(px, py) * 0.5
	_stamp_preview.visible = true


func _set_stamp_preview_visible(v: bool) -> void:
	if _stamp_preview != null and is_instance_valid(_stamp_preview):
		_stamp_preview.visible = v


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventPanGesture:
		if event.delta.y > 0.2:
			radius += 1
		if event.delta.y < -0.2:
			radius -= 1
		radius = clampi(radius, 2, 64)
