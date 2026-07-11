extends Node3D

## CellPond Rule Editor — standard Godot 3D scene.
## Uses Camera3D + MeshInstance3D cubes instead of VoxelWorld.
## Press R from the main world to enter, R/Escape to leave.

# Shared state persists across scene switches
static var shared_rule_set: CellPondRuleSet = null
static var return_scene: String = "res://demo/demo.tscn"
static var recent_swatches: Array = []  # Array of Color, most recent first

const ZONE_SIZE: int = 7
const ZONE_SPACING: float = 10.0
const CELL_SIZE: float = 1.0

const SYMMETRY_NAMES = ["None", "Rotate Y4", "Rotate All24", "Full 48"]
const MATERIAL_NAMES = ["Air", "Solid", "Water", "Lava", "Sand", "Vine"]
const UNTOUCHED: int = -1

# Default material colors (used as starting point for type selection)
const MATERIAL_COLORS = [
	Color(1.0, 1.0, 1.0, 0.15),  # 0: Air
	Color(0.6, 0.6, 0.6),        # 1: Solid
	Color(0.2, 0.4, 0.9, 0.8),   # 2: Water
	Color(1.0, 0.3, 0.1),        # 3: Lava
	Color(0.9, 0.8, 0.4),        # 4: Sand
	Color(0.2, 0.7, 0.2),        # 5: Vine
]

var camera_parent: Node3D
var camera_pivot: Node3D
var camera: Camera3D
var before_zone: Node3D
var after_zone: Node3D

# Grid data: flat arrays indexed as x + y*ZONE_SIZE + z*ZONE_SIZE*ZONE_SIZE
var before_grid: Array = []    # material ID per cell
var after_grid: Array = []
var before_colors: Array = []  # Color per cell (null for untouched/air)
var after_colors: Array = []
# Maps Vector3i -> Node3D (the cube body node) for removal
var before_meshes: Dictionary = {}
var after_meshes: Dictionary = {}

# Preview ghost cube
var preview_mesh: MeshInstance3D = null
var preview_material: StandardMaterial3D

var air_wireframe_mesh: Mesh

# Editing state
var symmetry_mode: int = 1
var selected_material: int = 1  # voxel TYPE (1-5, 0=air)
var selected_color: Color = Color(0.6, 0.6, 0.6)  # custom color for placement
var selected_color_mode: int = 0  # 0=solid, 1=random
var selected_color_min: Color = Color(0.6, 0.6, 0.6)  # range start (sRGB)
var selected_color_max: Color = Color(0.8, 0.8, 0.8)  # range end (sRGB)
var edit_cooldown: float = 0.0
var look_sensitivity: float = 0.1
var fly_speed: float = 8.0
var editing_rule_index: int = -1
var rule_chance: int = 100  # 0-100%

# 2D Color picker state
var picker_active: bool = false
var picker_panel: PanelContainer
var picker_sv_rect: TextureRect
var picker_sv_cursor: Label
var picker_h_slider: VSlider
var picker_preview: ColorRect
var picker_info_label: Label
var picker_random_check: CheckButton
var picker_random_container: VBoxContainer
var picker_range_sliders: Array = []  # [[min_slider, max_slider], ...] for H, S, V
var picker_preview_min: ColorRect
var picker_preview_max: ColorRect
var picker_h: float = 0.0
var picker_s: float = 0.0
var picker_v: float = 0.7
const SV_TEX_SIZE: int = 160

# HUD
var canvas_layer: CanvasLayer
var material_label: Label
var crosshair: Label
var color_swatch: ColorRect

func _ready() -> void:
	if shared_rule_set == null:
		shared_rule_set = CellPondRuleSet.new()
		shared_rule_set.activation_chance = 1

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	var grid_size = ZONE_SIZE * ZONE_SIZE * ZONE_SIZE
	before_grid.resize(grid_size); before_grid.fill(UNTOUCHED)
	after_grid.resize(grid_size); after_grid.fill(UNTOUCHED)
	before_colors.resize(grid_size); before_colors.fill(null)
	after_colors.resize(grid_size); after_colors.fill(null)

	_create_preview()
	_build_scene()
	_build_color_picker()

func _create_preview() -> void:
	preview_material = StandardMaterial3D.new()
	preview_material.albedo_color = Color(1, 1, 1, 0.3)
	preview_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	preview_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	preview_material.no_depth_test = true

	preview_mesh = MeshInstance3D.new()
	var box = BoxMesh.new()
	box.size = Vector3(1.0, 1.0, 1.0)
	preview_mesh.mesh = box
	preview_mesh.material_override = preview_material
	preview_mesh.visible = false

	# Create shared wireframe box mesh for air cells
	var im = ImmediateMesh.new()
	var wire_mat = StandardMaterial3D.new()
	wire_mat.albedo_color = Color(1.0, 1.0, 1.0, 0.3)
	wire_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wire_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var lo = -0.475; var hi = 0.475
	im.surface_begin(Mesh.PRIMITIVE_LINES, wire_mat)
	im.surface_add_vertex(Vector3(lo, lo, lo)); im.surface_add_vertex(Vector3(hi, lo, lo))
	im.surface_add_vertex(Vector3(hi, lo, lo)); im.surface_add_vertex(Vector3(hi, lo, hi))
	im.surface_add_vertex(Vector3(hi, lo, hi)); im.surface_add_vertex(Vector3(lo, lo, hi))
	im.surface_add_vertex(Vector3(lo, lo, hi)); im.surface_add_vertex(Vector3(lo, lo, lo))
	im.surface_add_vertex(Vector3(lo, hi, lo)); im.surface_add_vertex(Vector3(hi, hi, lo))
	im.surface_add_vertex(Vector3(hi, hi, lo)); im.surface_add_vertex(Vector3(hi, hi, hi))
	im.surface_add_vertex(Vector3(hi, hi, hi)); im.surface_add_vertex(Vector3(lo, hi, hi))
	im.surface_add_vertex(Vector3(lo, hi, hi)); im.surface_add_vertex(Vector3(lo, hi, lo))
	im.surface_add_vertex(Vector3(lo, lo, lo)); im.surface_add_vertex(Vector3(lo, hi, lo))
	im.surface_add_vertex(Vector3(hi, lo, lo)); im.surface_add_vertex(Vector3(hi, hi, lo))
	im.surface_add_vertex(Vector3(hi, lo, hi)); im.surface_add_vertex(Vector3(hi, hi, hi))
	im.surface_add_vertex(Vector3(lo, lo, hi)); im.surface_add_vertex(Vector3(lo, hi, hi))
	im.surface_end()
	air_wireframe_mesh = im

func _create_grid_lines(zone: Node3D, color: Color) -> void:
	var im = ImmediateMesh.new()
	var mesh_inst = MeshInstance3D.new()
	mesh_inst.name = "GridLines"
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, 0.08)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var s = float(ZONE_SIZE)
	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	for y in range(1, ZONE_SIZE):
		for z in range(ZONE_SIZE + 1):
			im.surface_add_vertex(Vector3(0, y, z)); im.surface_add_vertex(Vector3(s, y, z))
	for z in range(1, ZONE_SIZE):
		for y in range(ZONE_SIZE + 1):
			im.surface_add_vertex(Vector3(0, y, z)); im.surface_add_vertex(Vector3(s, y, z))
	for x in range(1, ZONE_SIZE):
		for z in range(ZONE_SIZE + 1):
			im.surface_add_vertex(Vector3(x, 0, z)); im.surface_add_vertex(Vector3(x, s, z))
	for z in range(1, ZONE_SIZE):
		for x in range(ZONE_SIZE + 1):
			im.surface_add_vertex(Vector3(x, 0, z)); im.surface_add_vertex(Vector3(x, s, z))
	for x in range(1, ZONE_SIZE):
		for y in range(ZONE_SIZE + 1):
			im.surface_add_vertex(Vector3(x, y, 0)); im.surface_add_vertex(Vector3(x, y, s))
	for y in range(1, ZONE_SIZE):
		for x in range(ZONE_SIZE + 1):
			im.surface_add_vertex(Vector3(x, y, 0)); im.surface_add_vertex(Vector3(x, y, s))
	im.surface_end()
	mesh_inst.mesh = im
	zone.add_child(mesh_inst)

func _build_scene() -> void:
	var env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.12, 0.12, 0.18)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.3, 0.3, 0.35)
	env.ambient_light_energy = 0.5
	var world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 30, 0)
	sun.light_color = Color(1.0, 0.95, 0.85)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	add_child(sun)

	camera_parent = Node3D.new()
	camera_parent.name = "CameraParent"
	camera_parent.position = Vector3(ZONE_SPACING / 2.0, float(ZONE_SIZE) / 2.0, ZONE_SIZE + 5.0)
	camera_pivot = Node3D.new()
	camera_pivot.name = "CameraPivot"
	camera_pivot.rotation.x = -0.3
	camera_parent.add_child(camera_pivot)
	camera = Camera3D.new()
	camera.fov = 70.0
	camera.current = true
	camera_pivot.add_child(camera)
	add_child(camera_parent)

	before_zone = Node3D.new()
	before_zone.name = "BeforeZone"
	before_zone.position = Vector3.ZERO
	add_child(before_zone)
	after_zone = Node3D.new()
	after_zone.name = "AfterZone"
	after_zone.position = Vector3(ZONE_SPACING, 0, 0)
	add_child(after_zone)

	_create_zone_outline(before_zone, Color.CYAN)
	_create_zone_outline(after_zone, Color.GREEN)
	_create_grid_lines(before_zone, Color.CYAN)
	_create_grid_lines(after_zone, Color.GREEN)
	_create_zone_floor(before_zone)
	_create_zone_floor(after_zone)
	add_child(preview_mesh)

	var before_label = Label3D.new()
	before_label.text = "BEFORE"
	before_label.font_size = 96
	before_label.modulate = Color.CYAN
	before_label.position = Vector3(float(ZONE_SIZE) / 2.0, float(ZONE_SIZE) + 0.5, float(ZONE_SIZE) / 2.0)
	before_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	before_zone.add_child(before_label)

	var after_label = Label3D.new()
	after_label.text = "AFTER"
	after_label.font_size = 96
	after_label.modulate = Color.GREEN
	after_label.position = Vector3(float(ZONE_SIZE) / 2.0, float(ZONE_SIZE) + 0.5, float(ZONE_SIZE) / 2.0)
	after_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	after_zone.add_child(after_label)

	# --- HUD ---
	canvas_layer = CanvasLayer.new()
	add_child(canvas_layer)

	var title = Label.new()
	title.text = "RULE EDITOR"
	title.position = Vector2(20, 20)
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color.WHITE)
	canvas_layer.add_child(title)

	material_label = Label.new()
	material_label.position = Vector2(20, 55)
	material_label.add_theme_font_size_override("font_size", 16)
	material_label.add_theme_color_override("font_color", Color.YELLOW)
	canvas_layer.add_child(material_label)

	# Color swatch showing selected color
	color_swatch = ColorRect.new()
	color_swatch.custom_minimum_size = Vector2(30, 30)
	color_swatch.position = Vector2(20, 80)
	color_swatch.color = selected_color
	canvas_layer.add_child(color_swatch)

	var controls = Label.new()
	controls.anchor_top = 1.0; controls.anchor_bottom = 1.0
	controls.anchor_left = 0.0; controls.anchor_right = 0.0
	controls.offset_top = -55; controls.offset_left = 20
	controls.add_theme_font_size_override("font_size", 13)
	controls.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	controls.text = "LClick=Place  RClick=Remove  MClick=Pick Color  0=Air  1-5=Type\nT=Symmetry  C=Color Picker  V=Random Mode  PgUp/Dn=Chance  Enter=Commit  Backspace=Clear  ←/→=Browse  R=Return"
	canvas_layer.add_child(controls)

	crosshair = Label.new()
	crosshair.text = "+"
	crosshair.add_theme_font_size_override("font_size", 32)
	crosshair.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	crosshair.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	crosshair.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	crosshair.anchor_left = 0.5; crosshair.anchor_right = 0.5
	crosshair.anchor_top = 0.5; crosshair.anchor_bottom = 0.5
	crosshair.offset_left = -20; crosshair.offset_right = 20
	crosshair.offset_top = -20; crosshair.offset_bottom = 20
	canvas_layer.add_child(crosshair)

func _build_color_picker() -> void:
	picker_panel = PanelContainer.new()
	picker_panel.visible = false
	picker_panel.position = Vector2(20, 120)
	picker_panel.mouse_filter = Control.MOUSE_FILTER_STOP

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.12, 0.18, 0.95)
	style.set_border_width_all(1)
	style.border_color = Color(0.4, 0.4, 0.5)
	style.set_content_margin_all(10)
	style.set_corner_radius_all(4)
	picker_panel.add_theme_stylebox_override("panel", style)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	picker_panel.add_child(vbox)

	var title_label = Label.new()
	title_label.text = "HSV Color Picker"
	title_label.add_theme_font_size_override("font_size", 14)
	vbox.add_child(title_label)

	# Top row: S-V plane + H slider
	var hbox_top = HBoxContainer.new()
	hbox_top.add_theme_constant_override("separation", 8)
	vbox.add_child(hbox_top)

	var sv_container = Control.new()
	sv_container.custom_minimum_size = Vector2(SV_TEX_SIZE, SV_TEX_SIZE)
	hbox_top.add_child(sv_container)

	picker_sv_rect = TextureRect.new()
	picker_sv_rect.custom_minimum_size = Vector2(SV_TEX_SIZE, SV_TEX_SIZE)
	picker_sv_rect.stretch_mode = TextureRect.STRETCH_SCALE
	picker_sv_rect.mouse_filter = Control.MOUSE_FILTER_STOP
	picker_sv_rect.gui_input.connect(_on_sv_input)
	sv_container.add_child(picker_sv_rect)

	picker_sv_cursor = Label.new()
	picker_sv_cursor.text = "+"
	picker_sv_cursor.add_theme_font_size_override("font_size", 20)
	picker_sv_cursor.add_theme_color_override("font_color", Color.WHITE)
	picker_sv_cursor.position = Vector2(SV_TEX_SIZE / 2 - 6, SV_TEX_SIZE / 2 - 12)
	sv_container.add_child(picker_sv_cursor)

	# H slider (vertical — hue rainbow)
	var h_vbox = VBoxContainer.new()
	h_vbox.add_theme_constant_override("separation", 2)
	hbox_top.add_child(h_vbox)

	var h_top_label = Label.new()
	h_top_label.text = "H"
	h_top_label.add_theme_font_size_override("font_size", 12)
	h_vbox.add_child(h_top_label)

	picker_h_slider = VSlider.new()
	picker_h_slider.min_value = 0.0
	picker_h_slider.max_value = 1.0
	picker_h_slider.step = 0.01
	picker_h_slider.value = picker_h
	picker_h_slider.custom_minimum_size = Vector2(24, SV_TEX_SIZE - 20)
	picker_h_slider.value_changed.connect(_on_h_changed)
	h_vbox.add_child(picker_h_slider)

	# Info row: preview swatch + HSV values
	var hbox_info = HBoxContainer.new()
	hbox_info.add_theme_constant_override("separation", 8)
	vbox.add_child(hbox_info)

	picker_preview = ColorRect.new()
	picker_preview.custom_minimum_size = Vector2(40, 25)
	picker_preview.color = selected_color
	hbox_info.add_child(picker_preview)

	picker_info_label = Label.new()
	picker_info_label.add_theme_font_size_override("font_size", 12)
	picker_info_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	hbox_info.add_child(picker_info_label)

	# Random mode toggle
	picker_random_check = CheckButton.new()
	picker_random_check.text = "Random Range"
	picker_random_check.button_pressed = selected_color_mode == 1
	picker_random_check.add_theme_font_size_override("font_size", 13)
	picker_random_check.toggled.connect(_on_random_toggled)
	vbox.add_child(picker_random_check)

	# Random range sliders container
	picker_random_container = VBoxContainer.new()
	picker_random_container.visible = selected_color_mode == 1
	picker_random_container.add_theme_constant_override("separation", 4)
	vbox.add_child(picker_random_container)

	picker_range_sliders = []
	var channels = [["H", 0.0, 1.0], ["S", 0.0, 1.0], ["V", 0.0, 1.0]]
	for ch in channels:
		var row = HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		picker_random_container.add_child(row)

		var ch_label = Label.new()
		ch_label.text = str(ch[0]) + ":"
		ch_label.custom_minimum_size = Vector2(20, 0)
		ch_label.add_theme_font_size_override("font_size", 12)
		row.add_child(ch_label)

		var min_slider = HSlider.new()
		min_slider.min_value = ch[1]
		min_slider.max_value = ch[2]
		min_slider.step = 0.01
		min_slider.custom_minimum_size = Vector2(80, 0)
		min_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		min_slider.value_changed.connect(_on_range_changed)
		row.add_child(min_slider)

		var to_label = Label.new()
		to_label.text = "-"
		to_label.add_theme_font_size_override("font_size", 12)
		row.add_child(to_label)

		var max_slider = HSlider.new()
		max_slider.min_value = ch[1]
		max_slider.max_value = ch[2]
		max_slider.step = 0.01
		max_slider.custom_minimum_size = Vector2(80, 0)
		max_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		max_slider.value_changed.connect(_on_range_changed)
		row.add_child(max_slider)

		picker_range_sliders.append([min_slider, max_slider])

	# Min/Max preview swatches
	var hbox_previews = HBoxContainer.new()
	hbox_previews.add_theme_constant_override("separation", 8)
	picker_random_container.add_child(hbox_previews)

	var min_label = Label.new()
	min_label.text = "Min:"
	min_label.add_theme_font_size_override("font_size", 12)
	hbox_previews.add_child(min_label)

	picker_preview_min = ColorRect.new()
	picker_preview_min.custom_minimum_size = Vector2(30, 20)
	hbox_previews.add_child(picker_preview_min)

	var max_label = Label.new()
	max_label.text = "Max:"
	max_label.add_theme_font_size_override("font_size", 12)
	hbox_previews.add_child(max_label)

	picker_preview_max = ColorRect.new()
	picker_preview_max.custom_minimum_size = Vector2(30, 20)
	hbox_previews.add_child(picker_preview_max)

	canvas_layer.add_child(picker_panel)
	_generate_sv_texture()
	_update_picker_info()

func _generate_sv_texture() -> void:
	var img = Image.create(SV_TEX_SIZE, SV_TEX_SIZE, false, Image.FORMAT_RGB8)
	for y in range(SV_TEX_SIZE):
		for x in range(SV_TEX_SIZE):
			var s_val = float(x) / SV_TEX_SIZE
			var v_val = 1.0 - float(y) / SV_TEX_SIZE
			var col = Color.from_hsv(picker_h, s_val, v_val)
			img.set_pixel(x, y, col)
	picker_sv_rect.texture = ImageTexture.create_from_image(img)

func _update_picker_info() -> void:
	picker_info_label.text = "H:%.2f S:%.2f V:%.2f" % [picker_h, picker_s, picker_v]
	selected_color = Color.from_hsv(picker_h, picker_s, picker_v)
	picker_preview.color = selected_color
	color_swatch.color = selected_color

	# Update cursor position on SV plane
	var cx = picker_s * SV_TEX_SIZE - 6
	var cy = (1.0 - picker_v) * SV_TEX_SIZE - 12
	picker_sv_cursor.position = Vector2(cx, cy)

	if selected_color_mode == 1 and picker_preview_min != null:
		selected_color_min = Color.from_hsv(
			picker_range_sliders[0][0].value,
			picker_range_sliders[1][0].value,
			picker_range_sliders[2][0].value)
		selected_color_max = Color.from_hsv(
			picker_range_sliders[0][1].value,
			picker_range_sliders[1][1].value,
			picker_range_sliders[2][1].value)
		picker_preview_min.color = selected_color_min
		picker_preview_max.color = selected_color_max

func _update_picker_from_color() -> void:
	picker_h = selected_color.h
	picker_s = selected_color.s
	picker_v = selected_color.v
	picker_h_slider.set_value_no_signal(picker_h)
	_generate_sv_texture()

	if selected_color_mode == 1:
		picker_range_sliders[0][0].set_value_no_signal(selected_color_min.h)
		picker_range_sliders[0][1].set_value_no_signal(selected_color_max.h)
		picker_range_sliders[1][0].set_value_no_signal(selected_color_min.s)
		picker_range_sliders[1][1].set_value_no_signal(selected_color_max.s)
		picker_range_sliders[2][0].set_value_no_signal(selected_color_min.v)
		picker_range_sliders[2][1].set_value_no_signal(selected_color_max.v)
	else:
		picker_range_sliders[0][0].set_value_no_signal(picker_h)
		picker_range_sliders[0][1].set_value_no_signal(picker_h)
		picker_range_sliders[1][0].set_value_no_signal(picker_s)
		picker_range_sliders[1][1].set_value_no_signal(picker_s)
		picker_range_sliders[2][0].set_value_no_signal(picker_v)
		picker_range_sliders[2][1].set_value_no_signal(picker_v)
	picker_random_check.set_pressed_no_signal(selected_color_mode == 1)
	picker_random_container.visible = selected_color_mode == 1
	_update_picker_info()

func _on_sv_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_pick_sv_from_pos(event.position)
	elif event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_pick_sv_from_pos(event.position)

func _pick_sv_from_pos(pos: Vector2) -> void:
	picker_s = clampf(pos.x / SV_TEX_SIZE, 0.0, 1.0)
	picker_v = clampf(1.0 - pos.y / SV_TEX_SIZE, 0.0, 1.0)
	_update_picker_info()

func _on_h_changed(value: float) -> void:
	picker_h = value
	_generate_sv_texture()
	_update_picker_info()

func _on_random_toggled(pressed: bool) -> void:
	selected_color_mode = 1 if pressed else 0
	picker_random_container.visible = pressed
	if pressed:
		picker_range_sliders[0][0].set_value_no_signal(picker_h)
		picker_range_sliders[0][1].set_value_no_signal(picker_h)
		picker_range_sliders[1][0].set_value_no_signal(picker_s)
		picker_range_sliders[1][1].set_value_no_signal(picker_s)
		picker_range_sliders[2][0].set_value_no_signal(picker_v)
		picker_range_sliders[2][1].set_value_no_signal(picker_v)
	_update_picker_info()

func _on_range_changed(_value: float) -> void:
	_update_picker_info()

func _create_zone_outline(zone: Node3D, color: Color) -> void:
	var im = ImmediateMesh.new()
	var mesh_inst = MeshInstance3D.new()
	mesh_inst.name = "Outline"
	var mat = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	var s = float(ZONE_SIZE)
	var lo = Vector3(-0.05, -0.05, -0.05)
	var hi = Vector3(s + 0.05, s + 0.05, s + 0.05)
	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	im.surface_add_vertex(Vector3(lo.x, lo.y, lo.z)); im.surface_add_vertex(Vector3(hi.x, lo.y, lo.z))
	im.surface_add_vertex(Vector3(hi.x, lo.y, lo.z)); im.surface_add_vertex(Vector3(hi.x, lo.y, hi.z))
	im.surface_add_vertex(Vector3(hi.x, lo.y, hi.z)); im.surface_add_vertex(Vector3(lo.x, lo.y, hi.z))
	im.surface_add_vertex(Vector3(lo.x, lo.y, hi.z)); im.surface_add_vertex(Vector3(lo.x, lo.y, lo.z))
	im.surface_add_vertex(Vector3(lo.x, hi.y, lo.z)); im.surface_add_vertex(Vector3(hi.x, hi.y, lo.z))
	im.surface_add_vertex(Vector3(hi.x, hi.y, lo.z)); im.surface_add_vertex(Vector3(hi.x, hi.y, hi.z))
	im.surface_add_vertex(Vector3(hi.x, hi.y, hi.z)); im.surface_add_vertex(Vector3(lo.x, hi.y, hi.z))
	im.surface_add_vertex(Vector3(lo.x, hi.y, hi.z)); im.surface_add_vertex(Vector3(lo.x, hi.y, lo.z))
	im.surface_add_vertex(Vector3(lo.x, lo.y, lo.z)); im.surface_add_vertex(Vector3(lo.x, hi.y, lo.z))
	im.surface_add_vertex(Vector3(hi.x, lo.y, lo.z)); im.surface_add_vertex(Vector3(hi.x, hi.y, lo.z))
	im.surface_add_vertex(Vector3(hi.x, lo.y, hi.z)); im.surface_add_vertex(Vector3(hi.x, hi.y, hi.z))
	im.surface_add_vertex(Vector3(lo.x, lo.y, hi.z)); im.surface_add_vertex(Vector3(lo.x, hi.y, hi.z))
	im.surface_end()
	mesh_inst.mesh = im
	zone.add_child(mesh_inst)

func _create_zone_floor(zone: Node3D) -> void:
	var floor_body = StaticBody3D.new()
	floor_body.name = "Floor"
	floor_body.position = Vector3(float(ZONE_SIZE) / 2.0, -0.5, float(ZONE_SIZE) / 2.0)
	var floor_shape = CollisionShape3D.new()
	var box = BoxShape3D.new()
	box.size = Vector3(float(ZONE_SIZE), 0.1, float(ZONE_SIZE))
	floor_shape.shape = box
	floor_body.add_child(floor_shape)
	var floor_mesh = MeshInstance3D.new()
	var floor_box = BoxMesh.new()
	floor_box.size = Vector3(float(ZONE_SIZE), 0.02, float(ZONE_SIZE))
	floor_mesh.mesh = floor_box
	var floor_mat = StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.2, 0.2, 0.25)
	floor_mesh.material_override = floor_mat
	floor_body.add_child(floor_mesh)
	floor_body.set_meta("zone", zone.name)
	floor_body.set_meta("is_floor", true)
	zone.add_child(floor_body)

func _grid_index(pos: Vector3i) -> int:
	return pos.x + pos.y * ZONE_SIZE + pos.z * ZONE_SIZE * ZONE_SIZE

func _is_in_bounds(pos: Vector3i) -> bool:
	return pos.x >= 0 and pos.x < ZONE_SIZE and pos.y >= 0 and pos.y < ZONE_SIZE and pos.z >= 0 and pos.z < ZONE_SIZE

func _get_grid(zone_name: String) -> Array:
	return before_grid if zone_name == "BeforeZone" else after_grid

func _get_colors(zone_name: String) -> Array:
	return before_colors if zone_name == "BeforeZone" else after_colors

func _get_meshes(zone_name: String) -> Dictionary:
	return before_meshes if zone_name == "BeforeZone" else after_meshes

func _get_zone_node(zone_name: String) -> Node3D:
	return before_zone if zone_name == "BeforeZone" else after_zone

func _place_cell(zone_name: String, cell: Vector3i, mat_id: int, color: Color = Color.BLACK) -> void:
	if not _is_in_bounds(cell) or mat_id < 0 or mat_id >= MATERIAL_COLORS.size():
		return

	var grid = _get_grid(zone_name)
	var colors = _get_colors(zone_name)
	var meshes = _get_meshes(zone_name)
	var zone_node = _get_zone_node(zone_name)
	var idx = _grid_index(cell)

	if meshes.has(cell):
		meshes[cell].queue_free()
		meshes.erase(cell)

	grid[idx] = mat_id
	colors[idx] = color if mat_id > 0 else null

	var body = StaticBody3D.new()
	body.position = Vector3(cell) + Vector3(0.5, 0.5, 0.5)
	body.set_meta("zone", zone_name)
	body.set_meta("cell", cell)

	var mesh_inst = MeshInstance3D.new()
	if mat_id == 0:
		mesh_inst.mesh = air_wireframe_mesh
	else:
		var box = BoxMesh.new()
		box.size = Vector3(0.95, 0.95, 0.95)
		mesh_inst.mesh = box
		# Use custom color per instance
		var mat = StandardMaterial3D.new()
		mat.albedo_color = color
		if mat_id == 2:  # Water — transparent
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color.a = 0.8
		mesh_inst.material_override = mat
	body.add_child(mesh_inst)

	var col = CollisionShape3D.new()
	var shape = BoxShape3D.new()
	shape.size = Vector3(1.0, 1.0, 1.0)
	col.shape = shape
	body.add_child(col)

	zone_node.add_child(body)
	meshes[cell] = body

func _remove_cell(zone_name: String, cell: Vector3i) -> void:
	if not _is_in_bounds(cell):
		return
	var grid = _get_grid(zone_name)
	var colors = _get_colors(zone_name)
	var meshes = _get_meshes(zone_name)
	var idx = _grid_index(cell)
	grid[idx] = UNTOUCHED
	colors[idx] = null
	if meshes.has(cell):
		meshes[cell].queue_free()
		meshes.erase(cell)

func _process(delta: float) -> void:
	edit_cooldown -= delta
	_update_hud()
	if not picker_active:
		_process_movement(delta)
		_process_editing()

func _update_hud() -> void:
	var rule_count = shared_rule_set.get_rule_count()
	var edit_str: String
	if editing_rule_index >= 0:
		edit_str = "Editing rule %d/%d" % [editing_rule_index + 1, rule_count]
	else:
		edit_str = "New rule"
	var color_mode_str = "Solid" if selected_color_mode == 0 else "Random"
	material_label.text = "Type: %s | Color: %s | Symmetry: %s | Chance: %d%% | %s | Rules: %d" % [
		MATERIAL_NAMES[selected_material],
		color_mode_str,
		SYMMETRY_NAMES[symmetry_mode],
		rule_chance,
		edit_str,
		rule_count
	]
	color_swatch.color = selected_color

func _process_movement(delta: float) -> void:
	var wish_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var direction = (camera_pivot.global_basis * Vector3(wish_dir.x, 0, wish_dir.y)).normalized()
	if Input.is_action_pressed("move_up"):
		direction += Vector3.UP
	if Input.is_action_pressed("move_down"):
		direction += Vector3.DOWN
	if direction.length() > 0.01:
		camera_parent.position += direction.normalized() * fly_speed * delta

func _get_placement_cell(collider: StaticBody3D, zone_node: Node3D, hit_pos: Vector3, hit_normal: Vector3) -> Vector3i:
	var hit_pos_local = zone_node.to_local(hit_pos)
	var place_pos: Vector3
	if collider.get_meta("is_floor", false):
		place_pos = hit_pos_local + hit_normal
	else:
		place_pos = hit_pos_local + hit_normal * 0.5
	return Vector3i(floor(place_pos.x), floor(place_pos.y), floor(place_pos.z))

func _process_editing() -> void:
	var space = get_world_3d().direct_space_state
	var from = camera.global_position
	var forward = -camera.global_transform.basis.z
	var to = from + forward * 50.0

	var query = PhysicsRayQueryParameters3D.create(from, to)
	var result = space.intersect_ray(query)

	if result.is_empty():
		preview_mesh.visible = false
		return

	var collider = result["collider"]
	if not collider is StaticBody3D:
		preview_mesh.visible = false
		return

	var zone_name: String = collider.get_meta("zone", "")
	if zone_name == "":
		preview_mesh.visible = false
		return

	var zone_node = _get_zone_node(zone_name)
	var hit_normal = result["normal"]
	var preview_cell = _get_placement_cell(collider, zone_node, result["position"], hit_normal)

	if _is_in_bounds(preview_cell):
		var preview_color = selected_color if selected_material > 0 else Color(1, 1, 1)
		preview_material.albedo_color = Color(preview_color.r, preview_color.g, preview_color.b, 0.3)
		preview_mesh.global_position = zone_node.global_position + Vector3(preview_cell) + Vector3(0.5, 0.5, 0.5)
		preview_mesh.visible = true
	else:
		preview_mesh.visible = false

	if edit_cooldown > 0.01:
		return

	if Input.is_action_pressed("left_click"):
		_place_cell(zone_name, preview_cell, selected_material, selected_color)
		edit_cooldown = 0.15
	elif Input.is_action_pressed("right_click"):
		if not collider.get_meta("is_floor", false):
			var cell: Vector3i = collider.get_meta("cell", Vector3i(-1, -1, -1))
			if cell != Vector3i(-1, -1, -1):
				_remove_cell(zone_name, cell)
				edit_cooldown = 0.15
	elif Input.is_action_pressed("middle_click"):
		# Color pick from existing voxel
		if not collider.get_meta("is_floor", false):
			var cell: Vector3i = collider.get_meta("cell", Vector3i(-1, -1, -1))
			if cell != Vector3i(-1, -1, -1):
				var grid = _get_grid(zone_name)
				var colors = _get_colors(zone_name)
				var idx = _grid_index(cell)
				var mat_id = grid[idx]
				if mat_id > 0:
					selected_material = mat_id
					if colors[idx] != null:
						selected_color = colors[idx]
					else:
						selected_color = MATERIAL_COLORS[mat_id]
					selected_color_min = selected_color
					if picker_active:
						_update_picker_from_color()
					print("[CellPond] Picked: %s color=%s" % [MATERIAL_NAMES[mat_id], selected_color])
				elif mat_id == 0:
					selected_material = 0
				edit_cooldown = 0.2

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and not picker_active:
		camera_parent.rotation.y += -event.relative.x * 0.025 * look_sensitivity
		camera_pivot.rotation.x += -event.relative.y * 0.025 * look_sensitivity
		camera_pivot.rotation.x = clamp(camera_pivot.rotation.x, -PI / 2.2, PI / 2.2)

	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_R, KEY_ESCAPE:
				if picker_active:
					_toggle_picker()
				else:
					_return_to_main()
			KEY_ENTER:
				_commit_rule()
			KEY_T:
				symmetry_mode = (symmetry_mode + 1) % 4
			KEY_BACKSPACE:
				_clear_zones()
			KEY_LEFT:
				_browse_rule(-1)
			KEY_RIGHT:
				_browse_rule(1)
			KEY_C:
				_toggle_picker()
			KEY_V:
				selected_color_mode = 1 - selected_color_mode
				if picker_active:
					picker_random_check.set_pressed_no_signal(selected_color_mode == 1)
					picker_random_container.visible = selected_color_mode == 1
					_update_picker_info()
				print("[CellPond] Color mode: %s" % ["Solid", "Random"][selected_color_mode])
			KEY_PAGEUP:
				rule_chance = clampi(rule_chance + 10, 0, 100)
			KEY_PAGEDOWN:
				rule_chance = clampi(rule_chance - 10, 0, 100)
			KEY_DELETE:
				if shared_rule_set.get_rule_count() > 0:
					shared_rule_set.remove_rule(shared_rule_set.get_rule_count() - 1)
					editing_rule_index = -1
					print("[CellPond] Removed last rule. Rules: ", shared_rule_set.get_rule_count())
			KEY_0:
				selected_material = 0
			KEY_1:
				selected_material = 1
				selected_color = MATERIAL_COLORS[1]
			KEY_2:
				selected_material = 2
				selected_color = MATERIAL_COLORS[2]
			KEY_3:
				selected_material = 3
				selected_color = MATERIAL_COLORS[3]
			KEY_4:
				selected_material = 4
				selected_color = MATERIAL_COLORS[4]
			KEY_5:
				selected_material = 5
				selected_color = MATERIAL_COLORS[5]

func _toggle_picker() -> void:
	picker_active = not picker_active
	picker_panel.visible = picker_active
	if picker_active:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_update_picker_from_color()
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _clear_zones() -> void:
	before_grid.fill(UNTOUCHED)
	after_grid.fill(UNTOUCHED)
	before_colors.fill(null)
	after_colors.fill(null)
	for node in before_meshes.values():
		node.queue_free()
	for node in after_meshes.values():
		node.queue_free()
	before_meshes.clear()
	after_meshes.clear()
	editing_rule_index = -1
	print("[CellPond] Zones cleared")

func _commit_rule() -> void:
	var center = Vector3i(ZONE_SIZE / 2, ZONE_SIZE / 2, ZONE_SIZE / 2)

	var pattern_offsets: Array[Vector3i] = []
	var pattern_types: PackedInt32Array = PackedInt32Array()
	var pattern_match_modes: PackedInt32Array = PackedInt32Array()
	var pattern_color_matches: PackedInt32Array = PackedInt32Array()
	var pattern_colors: PackedColorArray = PackedColorArray()

	var result_offsets: Array[Vector3i] = []
	var result_actions: PackedInt32Array = PackedInt32Array()
	var result_types: PackedInt32Array = PackedInt32Array()
	var result_colors: PackedColorArray = PackedColorArray()
	var result_color_modes: PackedInt32Array = PackedInt32Array()
	var result_colors_max: PackedColorArray = PackedColorArray()

	for x in range(ZONE_SIZE):
		for y in range(ZONE_SIZE):
			for z in range(ZONE_SIZE):
				var offset = Vector3i(x, y, z) - center
				var idx = _grid_index(Vector3i(x, y, z))

				var before_val: int = before_grid[idx]
				var after_val: int = after_grid[idx]

				if before_val == UNTOUCHED and after_val == UNTOUCHED:
					continue

				# PATTERN
				if before_val == 0:
					pattern_offsets.append(offset)
					pattern_types.append(0)
					pattern_match_modes.append(5)  # AIR_ONLY
					pattern_color_matches.append(0)
					pattern_colors.append(Color.BLACK)
				elif before_val > 0:
					pattern_offsets.append(offset)
					pattern_types.append(before_val)
					pattern_match_modes.append(0)  # EXACT_TYPE
					# Match on color if a custom color was placed
					var bcol = before_colors[idx]
					if bcol != null:
						pattern_color_matches.append(1)
						pattern_colors.append(bcol)
					else:
						pattern_color_matches.append(0)
						pattern_colors.append(Color.BLACK)
				elif before_val == UNTOUCHED and after_val >= 0:
					pattern_offsets.append(offset)
					pattern_types.append(0)
					pattern_match_modes.append(5)  # AIR_ONLY
					pattern_color_matches.append(0)
					pattern_colors.append(Color.BLACK)

				# RESULT
				var before_effective: int = before_val if before_val >= 0 else -1
				var after_effective: int = after_val if after_val >= 0 else -1

				# Check if color changed even if type is the same
				var color_changed := false
				if after_effective > 0 and after_effective == before_effective:
					var bc = before_colors[idx]
					var ac = after_colors[idx]
					if bc != null and ac != null and not bc.is_equal_approx(ac):
						color_changed = true
					elif (bc == null) != (ac == null):
						color_changed = true

				if after_effective >= 0 and (after_effective != before_effective or color_changed):
					result_offsets.append(offset)
					if after_effective == 0:
						result_actions.append(2)  # SET_AIR
						result_types.append(0)
						result_colors.append(Color.BLACK)
						result_color_modes.append(0)
						result_colors_max.append(Color.BLACK)
					else:
						result_actions.append(0)  # SET_TYPE_AND_COLOR
						result_types.append(after_effective)
						# Use stored per-cell color
						var cell_color = after_colors[idx]
						if cell_color == null:
							cell_color = MATERIAL_COLORS[after_effective]
						result_colors.append(cell_color)
						result_color_modes.append(selected_color_mode)
						result_colors_max.append(selected_color_max if selected_color_mode == 1 else cell_color)

	if result_offsets.size() == 0:
		print("[CellPond] No differences between BEFORE and AFTER")
		return

	if editing_rule_index >= 0:
		shared_rule_set.replace_rule(
			editing_rule_index,
			pattern_offsets, pattern_types, pattern_match_modes,
			pattern_color_matches, pattern_colors,
			result_offsets, result_actions, result_types,
			result_colors, result_color_modes, result_colors_max,
			symmetry_mode, 100, rule_chance)
		print("[CellPond] Rule %d replaced! Patterns: %d Results: %d" % [
			editing_rule_index + 1, pattern_offsets.size(), result_offsets.size()])
	else:
		shared_rule_set.add_rule_from_arrays(
			pattern_offsets, pattern_types, pattern_match_modes,
			pattern_color_matches, pattern_colors,
			result_offsets, result_actions, result_types,
			result_colors, result_color_modes, result_colors_max,
			symmetry_mode, 100, rule_chance)
		print("[CellPond] Rule committed! Patterns: ", pattern_offsets.size(),
			  " Results: ", result_offsets.size(),
			  " Total rules: ", shared_rule_set.get_rule_count())

	# Collect colors used in this rule as recent swatches
	_collect_swatches(pattern_colors, pattern_color_matches, result_colors)
	_clear_zones()

static func _add_swatch(col: Color) -> void:
	# Don't add near-black or duplicate colors
	if col.v < 0.01:
		return
	for existing in recent_swatches:
		if existing.is_equal_approx(col):
			return
	recent_swatches.insert(0, col)
	if recent_swatches.size() > 16:
		recent_swatches.resize(16)

static func _collect_swatches(pattern_colors: PackedColorArray, pattern_color_matches: PackedInt32Array, result_colors: PackedColorArray) -> void:
	for i in range(pattern_color_matches.size()):
		if pattern_color_matches[i] == 1 and i < pattern_colors.size():
			_add_swatch(pattern_colors[i])
	for col in result_colors:
		_add_swatch(col)

func _browse_rule(direction: int) -> void:
	var rule_count = shared_rule_set.get_rule_count()
	if rule_count == 0:
		return
	if editing_rule_index < 0:
		if direction > 0:
			_load_rule(0)
		else:
			_load_rule(rule_count - 1)
	else:
		var new_index = (editing_rule_index + direction) % rule_count
		if new_index < 0:
			new_index += rule_count
		_load_rule(new_index)

func _load_rule(index: int) -> void:
	var data: Dictionary = shared_rule_set.get_rule_data(index)
	if data.is_empty():
		return

	before_grid.fill(UNTOUCHED)
	after_grid.fill(UNTOUCHED)
	before_colors.fill(null)
	after_colors.fill(null)
	for node in before_meshes.values():
		node.queue_free()
	for node in after_meshes.values():
		node.queue_free()
	before_meshes.clear()
	after_meshes.clear()

	var center = Vector3i(ZONE_SIZE / 2, ZONE_SIZE / 2, ZONE_SIZE / 2)
	var pattern_offsets: Array = data["pattern_offsets"]
	var pattern_types: PackedInt32Array = data["pattern_types"]
	var pattern_match_modes: PackedInt32Array = data["pattern_match_modes"]
	var pattern_color_matches: PackedInt32Array = data.get("pattern_color_matches", PackedInt32Array())
	var pattern_colors: PackedColorArray = data.get("pattern_colors", PackedColorArray())
	var result_offsets: Array = data["result_offsets"]
	var result_actions: PackedInt32Array = data["result_actions"]
	var result_types: PackedInt32Array = data["result_types"]
	var result_colors: PackedColorArray = data["result_colors"]

	# Populate BEFORE grid from pattern entries
	for i in range(pattern_offsets.size()):
		var offset: Vector3i = pattern_offsets[i]
		var cell: Vector3i = offset + center
		if not _is_in_bounds(cell):
			continue
		var mode: int = pattern_match_modes[i]
		if mode == 5:  # AIR_ONLY
			_place_cell("BeforeZone", cell, 0)
		elif mode == 0:  # EXACT_TYPE
			var mat_type: int = pattern_types[i]
			if mat_type >= 0 and mat_type < MATERIAL_COLORS.size():
				var col: Color = MATERIAL_COLORS[mat_type]
				if i < pattern_color_matches.size() and pattern_color_matches[i] == 1 and i < pattern_colors.size():
					col = pattern_colors[i]
				_place_cell("BeforeZone", cell, mat_type, col)

	# Copy BEFORE to AFTER
	for x in range(ZONE_SIZE):
		for y in range(ZONE_SIZE):
			for z in range(ZONE_SIZE):
				var cell = Vector3i(x, y, z)
				var idx = _grid_index(cell)
				var val = before_grid[idx]
				if val != UNTOUCHED:
					var col = before_colors[idx] if before_colors[idx] != null else Color.BLACK
					_place_cell("AfterZone", cell, val, col)

	# Apply result diffs on AFTER grid
	for i in range(result_offsets.size()):
		var offset: Vector3i = result_offsets[i]
		var cell: Vector3i = offset + center
		if not _is_in_bounds(cell):
			continue
		var action: int = result_actions[i]
		if action == 2:  # SET_AIR
			_place_cell("AfterZone", cell, 0)
		elif action == 0:  # SET_TYPE_AND_COLOR
			var mat_type: int = result_types[i]
			var col: Color = result_colors[i] if i < result_colors.size() else MATERIAL_COLORS[mat_type]
			if mat_type >= 0 and mat_type < MATERIAL_COLORS.size():
				_place_cell("AfterZone", cell, mat_type, col)

	symmetry_mode = data["symmetry_mode"]
	rule_chance = data.get("chance", 100)
	editing_rule_index = index
	print("[CellPond] Loaded rule %d for editing" % [index + 1])

func _return_to_main() -> void:
	get_tree().change_scene_to_file(return_scene)
