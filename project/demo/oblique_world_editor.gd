extends Node3D
## Cursor-based voxel drawing for the oblique VoxelCamera.
##
## Translation of world_editor.gd's drawing functions: instead of casting one
## ray from the camera crosshair, rays are built under the mouse cursor using
## the same parallel-ray construction as voxel_renderer_oblique.glsl — origins
## spread across a view plane through the camera position, all rays sharing
## one sheared direction. Requires a visible mouse cursor.

@export var world: VoxelWorld
@export var voxel_camera: Node3D  # VoxelCamera

@export var selected_material: int = 1
@export var radius: int = 4
## 0 = place/remove, 1 = smooth
@export var brush_mode: int = 0

@export_group("Oblique projection — must match voxel_renderer_oblique.glsl")
@export var oblique_angle_degrees: float = 270.0
@export var oblique_strength: float = 1.0
@export var oblique_focus_distance: float = 60.0
@export var oblique_pullback: float = 0.0

const RAY_DISTANCE := 1000.0

const MATERIAL_TO_VOXEL_TYPE = {1: 1, 2: 4, 3: 2, 4: 3, 5: 5}
const MATERIAL_DEFAULT_COLORS = {
	1: Color(0.24, 0.25, 0.32),  # Rock (gray)
	2: Color(0.91, 0.82, 0.52),  # Sand (tan)
	3: Color(0.2, 0.4, 0.8),     # Water (blue)
	4: Color(0.9, 0.3, 0.1),     # Lava (orange-red)
	5: Color(0.2, 0.7, 0.15),    # Vine (green)
}

var selected_color: Color = MATERIAL_DEFAULT_COLORS[1]
var cooldown := 0.0


func set_selected_material(value: int) -> void:
	selected_material = value
	if MATERIAL_DEFAULT_COLORS.has(value):
		selected_color = MATERIAL_DEFAULT_COLORS[value]


func compress_color16(col: Color) -> int:
	var h := int(col.h * 127.0)
	var s := int(col.s * 15.0)
	var v := int(col.v * 31.0)
	return (h << 9) | (s << 5) | v


func _get_edit_value() -> int:
	if selected_material == 0:
		return 0  # air
	var voxel_type = MATERIAL_TO_VOXEL_TYPE.get(selected_material, 1)
	# Encoding: (voxel_type << 24) | (1 << 16) | color16
	return (voxel_type << 24) | (1 << 16) | compress_color16(selected_color)


## Ray under the mouse cursor in the oblique projection.
## Returns {} when the cursor is outside the rendered view.
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

	return {"origin": origin, "dir": dir}


func _process(delta: float) -> void:
	cooldown -= delta

	# Toggle brush mode with Tab
	if Input.is_action_just_pressed("change_brush"):
		brush_mode = (brush_mode + 1) % 2

	if Input.is_action_pressed("scroll_down"):
		if radius >= 4:
			radius -= 2
	if Input.is_action_pressed("scroll_up"):
		if radius <= 62:
			radius += 2

	var ray := _mouse_ray()
	if ray.is_empty():
		world.clear_brush_preview()
		return

	# Brush preview follows the cursor
	var hit_pos: Vector3 = world.raycast_world(ray.origin, ray.dir, RAY_DISTANCE)
	if hit_pos.x >= 0:
		world.set_brush_preview(hit_pos, radius)
	else:
		world.clear_brush_preview()

	if brush_mode == 0:
		# Place/remove mode
		if Input.is_action_pressed("left_click") and cooldown < 0.01:
			world.edit_world(ray.origin, ray.dir, radius, RAY_DISTANCE, _get_edit_value())
			cooldown = 0.1
		if Input.is_action_pressed("right_click") and cooldown < 0.01:
			world.edit_world(ray.origin, ray.dir, radius, RAY_DISTANCE, 0)
			cooldown = 0.1
	elif brush_mode == 1:
		# Smooth mode
		if Input.is_action_pressed("left_click") and cooldown < 0.01:
			world.edit_world_smooth(ray.origin, ray.dir, radius, RAY_DISTANCE)
			cooldown = 0.1


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventPanGesture:
		if event.delta.y > 0.2:
			radius += 1
		if event.delta.y < -0.2:
			radius -= 1
		radius = clampi(radius, 2, 64)
