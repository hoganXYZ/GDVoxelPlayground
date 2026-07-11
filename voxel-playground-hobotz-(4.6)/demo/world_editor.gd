extends Node3D

@export var world : VoxelWorld
@export var selected_material : int = 1
@export var radius : int = 1
## 0 = place/remove, 1 = smooth
@export var brush_mode : int = 0

var cooldown := 0.0
var _rule_editor_key_held := false

# Custom color support
var selected_color: Color = Color(0.24, 0.25, 0.32)  # default rock gray
var picker_active: bool = false

# Material selection index → actual voxel type constant
const MATERIAL_TO_VOXEL_TYPE = {1: 1, 2: 4, 3: 2, 4: 3, 5: 5}
# Default colors per material slot
const MATERIAL_DEFAULT_COLORS = {
	1: Color(0.24, 0.25, 0.32),  # Rock (gray)
	2: Color(0.91, 0.82, 0.52),  # Sand (tan)
	3: Color(0.2, 0.4, 0.8),    # Water (blue)
	4: Color(0.9, 0.3, 0.1),    # Lava (orange-red)
	5: Color(0.2, 0.7, 0.15),   # Vine (green)
}

# 2D color picker UI
var canvas_layer: CanvasLayer
var picker_panel: PanelContainer
var picker_preview: ColorRect
var picker_h_slider: HSlider
var picker_s_slider: HSlider
var picker_v_slider: HSlider
var picker_info_label: Label
var swatch_container: GridContainer
var _last_swatch_count: int = -1

func set_selected_material(value: int) -> void:
	selected_material = value
	if MATERIAL_DEFAULT_COLORS.has(value):
		selected_color = MATERIAL_DEFAULT_COLORS[value]
		_update_picker_from_color()

func _ready() -> void:
	_build_color_picker()
	_apply_shared_rules()

func _apply_shared_rules() -> void:
	var rule_editor_script = load("res://demo/rule_editor.gd")
	var rule_set = rule_editor_script.get("shared_rule_set")
	if rule_set != null and rule_set.get_rule_count() > 0:
		world.cellpond_rules = rule_set
		await get_tree().process_frame
		await get_tree().process_frame
		world.upload_cellpond_rules()
		print("[CellPond] Applied %d rules from rule editor" % rule_set.get_rule_count())

func compress_color16(col: Color) -> int:
	var h := int(col.h * 127.0)
	var s := int(col.s * 15.0)
	var v := int(col.v * 31.0)
	return (h << 9) | (s << 5) | v

func _get_edit_value() -> int:
	if selected_material == 0:
		return 0  # air
	var voxel_type = MATERIAL_TO_VOXEL_TYPE.get(selected_material, 1)
	var color16 = compress_color16(selected_color)
	# Encoding: (voxel_type << 24) | (1 << 16) | color16
	return (voxel_type << 24) | (1 << 16) | color16

func _build_color_picker() -> void:
	canvas_layer = CanvasLayer.new()
	canvas_layer.layer = 10
	add_child(canvas_layer)

	picker_panel = PanelContainer.new()
	picker_panel.position = Vector2(10, 10)
	picker_panel.visible = false
	canvas_layer.add_child(picker_panel)

	var vbox = VBoxContainer.new()
	picker_panel.add_child(vbox)

	var title = Label.new()
	title.text = "Color Picker (C to toggle)"
	vbox.add_child(title)

	# Color preview
	picker_preview = ColorRect.new()
	picker_preview.custom_minimum_size = Vector2(200, 40)
	picker_preview.color = selected_color
	vbox.add_child(picker_preview)

	# H slider
	var h_label = Label.new()
	h_label.text = "Hue"
	vbox.add_child(h_label)
	picker_h_slider = HSlider.new()
	picker_h_slider.min_value = 0.0
	picker_h_slider.max_value = 1.0
	picker_h_slider.step = 0.01
	picker_h_slider.value = selected_color.h
	picker_h_slider.custom_minimum_size = Vector2(200, 20)
	picker_h_slider.value_changed.connect(_on_hsv_changed)
	vbox.add_child(picker_h_slider)

	# S slider
	var s_label = Label.new()
	s_label.text = "Saturation"
	vbox.add_child(s_label)
	picker_s_slider = HSlider.new()
	picker_s_slider.min_value = 0.0
	picker_s_slider.max_value = 1.0
	picker_s_slider.step = 0.01
	picker_s_slider.value = selected_color.s
	picker_s_slider.custom_minimum_size = Vector2(200, 20)
	picker_s_slider.value_changed.connect(_on_hsv_changed)
	vbox.add_child(picker_s_slider)

	# V slider
	var v_label = Label.new()
	v_label.text = "Value"
	vbox.add_child(v_label)
	picker_v_slider = HSlider.new()
	picker_v_slider.min_value = 0.0
	picker_v_slider.max_value = 1.0
	picker_v_slider.step = 0.01
	picker_v_slider.value = selected_color.v
	picker_v_slider.custom_minimum_size = Vector2(200, 20)
	picker_v_slider.value_changed.connect(_on_hsv_changed)
	vbox.add_child(picker_v_slider)

	# Info label
	picker_info_label = Label.new()
	picker_info_label.text = ""
	vbox.add_child(picker_info_label)

	# Recent swatches from rules
	var swatch_label = Label.new()
	swatch_label.text = "Rule Swatches"
	vbox.add_child(swatch_label)

	swatch_container = GridContainer.new()
	swatch_container.columns = 8
	swatch_container.add_theme_constant_override("h_separation", 2)
	swatch_container.add_theme_constant_override("v_separation", 2)
	vbox.add_child(swatch_container)

	_update_picker_info()
	_rebuild_swatches()

func _on_hsv_changed(_value: float) -> void:
	selected_color = Color.from_hsv(picker_h_slider.value, picker_s_slider.value, picker_v_slider.value)
	picker_preview.color = selected_color
	_update_picker_info()

func _update_picker_from_color() -> void:
	if picker_h_slider == null:
		return
	picker_h_slider.value = selected_color.h
	picker_s_slider.value = selected_color.s
	picker_v_slider.value = selected_color.v
	picker_preview.color = selected_color
	_update_picker_info()

func _update_picker_info() -> void:
	if picker_info_label == null:
		return
	picker_info_label.text = "RGB: (%.2f, %.2f, %.2f)" % [selected_color.r, selected_color.g, selected_color.b]

func _rebuild_swatches() -> void:
	if swatch_container == null:
		return
	var rule_editor_script = load("res://demo/rule_editor.gd")
	var swatches: Array = rule_editor_script.get("recent_swatches")
	if swatches == null:
		swatches = []

	# Also scan existing rules for colors if swatches are empty
	if swatches.size() == 0:
		var rule_set = rule_editor_script.get("shared_rule_set")
		if rule_set != null:
			for i in range(rule_set.get_rule_count()):
				var data = rule_set.get_rule_data(i)
				var pcm: PackedInt32Array = data.get("pattern_color_matches", PackedInt32Array())
				var pc: PackedColorArray = data.get("pattern_colors", PackedColorArray())
				var rc: PackedColorArray = data.get("result_colors", PackedColorArray())
				# Collect pattern colors with color matching
				for j in range(pcm.size()):
					if pcm[j] == 1 and j < pc.size() and pc[j].v > 0.01:
						if not swatches.has(pc[j]):
							swatches.append(pc[j])
				# Collect result colors
				for col in rc:
					if col.v > 0.01 and not swatches.has(col):
						swatches.append(col)
			# Store back to static var
			rule_editor_script.set("recent_swatches", swatches)

	# Clear old buttons
	for child in swatch_container.get_children():
		child.queue_free()

	for col in swatches:
		var btn = Button.new()
		btn.custom_minimum_size = Vector2(24, 24)
		var style_normal = StyleBoxFlat.new()
		style_normal.bg_color = col
		style_normal.set_corner_radius_all(2)
		btn.add_theme_stylebox_override("normal", style_normal)
		btn.add_theme_stylebox_override("hover", style_normal)
		btn.add_theme_stylebox_override("pressed", style_normal)
		btn.add_theme_stylebox_override("focus", style_normal)
		btn.pressed.connect(_on_swatch_pressed.bind(col))
		swatch_container.add_child(btn)

	_last_swatch_count = swatches.size()

func _on_swatch_pressed(col: Color) -> void:
	selected_color = col
	_update_picker_from_color()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_C and not event.shift_pressed:
			_toggle_picker()

func _toggle_picker() -> void:
	picker_active = !picker_active
	picker_panel.visible = picker_active
	if picker_active:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_update_picker_from_color()
		_rebuild_swatches()
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventPanGesture:
		if event.delta.y > 0.2:
			radius += 1
		if event.delta.y < -0.2:
			radius -= 1
		
		radius = clampi(radius, 2, 64)
			
func _process(delta: float) -> void:
	cooldown -= delta

	# Toggle color picker with C key (handled in _input)

	# Switch to rule editor with R key
	if Input.is_key_pressed(KEY_R) and not Input.is_key_pressed(KEY_SHIFT):
		if not _rule_editor_key_held:
			_rule_editor_key_held = true
			get_tree().change_scene_to_file("res://demo/rule_editor_scene.tscn")
			return
	else:
		_rule_editor_key_held = false

	# Don't process editing when picker is active
	if picker_active:
		return

	# Toggle brush mode with Tab
	if Input.is_action_just_pressed("change_brush"):
		brush_mode = (brush_mode + 1) % 2

	if Input.is_action_pressed("scroll_down"):
		if radius >= 4:
			radius -= 2
		print(radius)
	if Input.is_action_pressed("scroll_up"):
		if radius <= 62:
			radius += 2
		print(radius)

	# Update brush preview every frame
	var hit_pos = world.raycast_world(global_position, -global_transform.basis.z, 1000)
	if hit_pos.x >= 0:
		world.set_brush_preview(hit_pos, radius)
	else:
		world.clear_brush_preview()

	if brush_mode == 0:
		# Place/remove mode
		if Input.is_action_pressed("left_click"):
			if cooldown < 0.01:
				world.edit_world(global_position, -global_transform.basis.z, radius, 1000, _get_edit_value());
				cooldown = 0.1
		if Input.is_action_pressed("right_click"):
			if cooldown < 0.01:
				world.edit_world(global_position, -global_transform.basis.z, radius, 1000, 0);
				cooldown = 0.1
	elif brush_mode == 1:
		# Smooth mode
		if Input.is_action_pressed("left_click"):
			if cooldown < 0.01:
				world.edit_world_smooth(global_position, -global_transform.basis.z, radius, 1000);
				cooldown = 0.1
