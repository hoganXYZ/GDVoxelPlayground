class_name TextureProjector
extends Node3D
## Projects a SubViewport texture into the voxel world.
##
## Screen-space mode (default, `voxel_camera` assigned): the texture is mapped
## over the oblique VoxelCamera's view — every opaque texel stamps the voxel
## surface visible at that screen position, using the same parallel-ray
## construction as voxel_renderer_oblique.glsl / oblique_world_editor.gd.
##
## Standalone mode (`voxel_camera` unset): this node acts as a perspective
## projector aiming along its own -Z, like a video projector.
##
## Builds its own SubViewport with a white text label by default; assign
## `source_viewport` to project any other viewport instead. Toggle with P.

@export var world: VoxelWorld
## Oblique VoxelCamera to project from (screen-space mode). Leave unset to
## project from this node's own transform instead.
@export var voxel_camera: Node3D
## Optional external viewport to project. Leave unset to use the built-in text label.
@export var source_viewport: SubViewport
@export var text := "HELLO"
@export_range(8, 256) var font_size := 96
## Element to stamp: 0 erase, 1 rock, 2 sand, 3 water, 4 lava, 5 vine
@export var material_value := 2
## Multiplied into the texture color (white text * tint = tinted voxels).
@export var tint := Color.WHITE
@export var max_range := 1000.0
@export var alpha_threshold := 0.5
## false = convert the surface voxel (paint), true = spawn into the air in
## front of the surface (emitter; good for sand/water so it doesn't eat walls).
@export var place_on_surface := false
@export var active := false

@export_group("Standalone projector")
@export var fov_degrees := 30.0

@export_group("Oblique projection — must match voxel_renderer_oblique.glsl")
@export var oblique_angle_degrees: float = 270.0
@export var oblique_strength: float = 1.0
@export var oblique_focus_distance: float = 60.0
@export var oblique_pullback: float = 0.0

var _viewport: SubViewport
var _label: Label

func _ready() -> void:
	if source_viewport != null:
		_viewport = source_viewport
		return
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(512, 256)
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)

	_label = Label.new()
	_label.text = text
	_label.add_theme_font_size_override("font_size", font_size)
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_viewport.add_child(_label)

func _process(_delta: float) -> void:
	if Input.is_key_pressed(KEY_P):
		if not get_meta("p_held", false):
			active = not active
			set_meta("p_held", true)
	else:
		set_meta("p_held", false)

	if not active or world == null or _viewport == null:
		return
	if _label != null and _label.text != text:
		_label.text = text

	var tex := _viewport.get_texture()
	if tex == null:
		return
	var rd_rid := RenderingServer.texture_get_rd_texture(tex.get_rid())
	if not rd_rid.is_valid():
		return  # viewport hasn't rendered yet

	if voxel_camera != null:
		_project_screen_space(rd_rid)
	else:
		_project_standalone(rd_rid)

## Map the texture over the oblique camera's full view: parallel rays with the
## same view-plane spread and sheared direction the renderer uses, so texel
## (u, v) lands exactly on the voxel surface shown at screen position (u, v).
func _project_screen_space(rd_rid: RID) -> void:
	var cam_basis: Basis = voxel_camera.global_transform.basis
	var forward: Vector3 = -cam_basis.z
	var right: Vector3 = cam_basis.x
	var up: Vector3 = cam_basis.y

	# Aspect of the camera's render target, same as oblique_world_editor.gd.
	var render_tex = voxel_camera.get_render_texture()
	var aspect := 1.0
	if render_tex != null and render_tex.get_height() > 0:
		aspect = float(render_tex.get_width()) / float(render_tex.get_height())

	var half_height: float = tan(deg_to_rad(voxel_camera.fov) * 0.5) * oblique_focus_distance
	var half_width: float = half_height * aspect

	var origin: Vector3 = voxel_camera.global_position - forward * oblique_pullback
	var oblique_angle := deg_to_rad(oblique_angle_degrees)
	var shear := Vector2(cos(oblique_angle), sin(oblique_angle)) * oblique_strength
	var dir := (forward - right * shear.x - up * shear.y).normalized()

	world.project_texture_parallel(rd_rid, _viewport.size, origin,
			right * half_width, up * half_height, dir,
			_encode_value(), tint, alpha_threshold, max_range, place_on_surface)

## Perspective projector along this node's -Z.
func _project_standalone(rd_rid: RID) -> void:
	var size := _viewport.size
	var aspect := float(size.x) / float(size.y)
	var proj := Projection.create_perspective(fov_degrees, aspect, 0.05, max_range, false)
	var view_proj := proj * Projection(global_transform.affine_inverse())
	world.project_texture(rd_rid, size, view_proj.inverse(), global_position,
			_encode_value(), tint, alpha_threshold, max_range, place_on_surface)

func _encode_value() -> int:
	# Legacy material index, same as world_editor.gd (0 = erase/air).
	return material_value
