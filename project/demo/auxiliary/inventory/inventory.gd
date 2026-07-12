extends Control

## Dynamic element palette: one swatch per paintable element in the world's
## VoxelElementSet. Rebuilds automatically when the set changes (e.g. when the
## element editor adds a material at runtime). Number keys 1-9/0 select the
## first ten; click selects any. F toggles the element editor panel.

const ElementEditorPanel := preload("res://demo/auxiliary/inventory/element_editor.gd")

@export var selected_slot: int = 0
@export var slots: Array[Control]  # legacy export, unused
@export var world_editor: Node

const HIDDEN_ELEMENTS := ["air", "entity", "debug", ""]
const SWATCH_SIZE := Vector2(34, 34)

var _world: VoxelWorld
var _swatches: Array[Control] = []
var _element_ids: Array[int] = []
var _editor_panel: Control


func _ready() -> void:
	add_to_group("ca_ui_blocking")
	# the scene positions this control for the old 4-slot bar; take the full
	# bottom edge and center the swatches instead
	set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	offset_top = -64.0
	offset_bottom = -6.0
	offset_left = 6.0
	offset_right = -6.0
	var box: HBoxContainer = $HBoxContainer
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.alignment = BoxContainer.ALIGNMENT_CENTER

	_world = world_editor.world
	if _world == null:
		push_error("Element palette: world editor has no world")
		return
	_connect_set.call_deferred()


func _connect_set() -> void:
	var element_set = _world.element_set
	if element_set == null:
		# world not initialized yet; retry next frame
		_connect_set.call_deferred()
		return
	if not element_set.changed.is_connected(_rebuild):
		element_set.changed.connect(_rebuild)
	_rebuild()
	select_slot(0)

	_editor_panel = ElementEditorPanel.new()
	_editor_panel.world = _world
	get_parent().add_child.call_deferred(_editor_panel)


func _rebuild() -> void:
	var box: HBoxContainer = $HBoxContainer
	for child in box.get_children():
		child.queue_free()
	_swatches.clear()
	_element_ids.clear()

	var element_set = _world.element_set
	for id in element_set.get_element_count():
		var element = element_set.get_element(id)
		if element == null or HIDDEN_ELEMENTS.has(element.element_name):
			continue
		var slot := _make_swatch(element, _element_ids.size())
		box.add_child(slot)
		_swatches.append(slot)
		_element_ids.append(id)

	# keep the current selection valid after a rebuild
	if selected_slot >= _element_ids.size():
		selected_slot = 0
	if not _element_ids.is_empty():
		select_slot(selected_slot)


func _make_swatch(element, slot_index: int) -> Control:
	var container := VBoxContainer.new()
	container.custom_minimum_size = SWATCH_SIZE + Vector2(0, 16)

	var rect := ColorRect.new()
	rect.color = element.base_color
	rect.custom_minimum_size = SWATCH_SIZE
	rect.tooltip_text = element.element_name
	rect.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			select_slot(slot_index)
	)
	container.add_child(rect)

	var label := Label.new()
	label.text = element.element_name
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 9)
	label.clip_text = true # long names must not widen the slot
	container.add_child(label)
	return container


func select_slot(new_slot: int) -> void:
	if new_slot < 0 or new_slot >= _element_ids.size():
		return
	selected_slot = new_slot
	for i in _swatches.size():
		_swatches[i].modulate = Color(1, 1, 1, 1) if i == new_slot else Color(0.5, 0.5, 0.5, 0.6)

	var id: int = _element_ids[new_slot]
	var element = _world.element_set.get_element(id)
	world_editor.select_element(id, element.base_color)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode >= KEY_1 and event.keycode <= KEY_9:
			select_slot(event.keycode - KEY_1)
		elif event.keycode == KEY_0:
			select_slot(9)
