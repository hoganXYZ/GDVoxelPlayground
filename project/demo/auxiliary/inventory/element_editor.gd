extends PanelContainer

## Runtime element editor (Phase 5): create or modify VoxelElements while the
## simulation runs. Toggle with F. Applying uploads the GPU tables immediately
## (and recompiles the Tier-4 custom pass when the GLSL snippet changed);
## the palette refreshes itself through the element set's changed signal.

var world: VoxelWorld

const CLASS_NAMES := ["Static", "Powder", "Liquid", "Gas", "Custom"]
const OP_NAMES := ["None", "Move1", "Move2", "Swap", "Support", "Create", "Change", "Delete"]
const SYM_NAMES := ["None", "RotateY", "All"]

var _load_picker: OptionButton
var _name_edit: LineEdit
var _class_picker: OptionButton
var _color_picker: ColorPickerButton
var _density: SpinBox
var _flow: SpinBox
var _emission: SpinBox
var _initial_temp: SpinBox
var _conduct: SpinBox
var _temp_high: SpinBox
var _state_high: LineEdit
var _temp_low: SpinBox
var _state_low: LineEdit
var _life: SpinBox
var _life_into: LineEdit
var _reaction_rows: VBoxContainer
var _op_rows: VBoxContainer
var _glsl_edit: TextEdit
var _status: Label


func _ready() -> void:
	visible = false
	add_to_group("ca_ui_blocking")
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	offset_left = -460.0
	offset_top = 8.0
	offset_bottom = -8.0
	offset_right = -8.0
	_build_ui()
	_refresh_load_picker()
	if world and world.element_set:
		world.element_set.changed.connect(_refresh_load_picker)


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F:
		visible = not visible


# -------------------------------------------------- UI construction

func _spin(min_v: float, max_v: float, step: float, value: float, width := 70.0) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step
	s.value = value
	s.custom_minimum_size.x = width
	return s


func _labeled(grid: GridContainer, text: String, control: Control) -> void:
	var l := Label.new()
	l.text = text
	grid.add_child(l)
	grid.add_child(control)


func _build_ui() -> void:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(root)

	var title := Label.new()
	title.text = "Element Editor  —  press F to close"
	root.add_child(title)

	var load_row := HBoxContainer.new()
	load_row.add_child(_make_label("Load:"))
	_load_picker = OptionButton.new()
	_load_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_load_picker.item_selected.connect(_on_load_selected)
	load_row.add_child(_load_picker)
	root.add_child(load_row)

	var grid := GridContainer.new()
	grid.columns = 2
	root.add_child(grid)

	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "element name"
	_labeled(grid, "Name", _name_edit)

	_class_picker = OptionButton.new()
	for n in CLASS_NAMES:
		_class_picker.add_item(n)
	_labeled(grid, "Class", _class_picker)

	_color_picker = ColorPickerButton.new()
	_color_picker.color = Color(0.6, 0.6, 0.6)
	_color_picker.custom_minimum_size = Vector2(90, 24)
	_labeled(grid, "Color", _color_picker)

	_density = _spin(0.001, 10000.0, 1.0, 1000.0)
	_labeled(grid, "Density", _density)
	_flow = _spin(0.0, 1.0, 0.01, 1.0)
	_labeled(grid, "Flow", _flow)
	_emission = _spin(0.0, 4.0, 0.1, 0.0)
	_labeled(grid, "Emission", _emission)
	_initial_temp = _spin(0.0, 4000.0, 1.0, 293.0)
	_labeled(grid, "Temp K", _initial_temp)
	_conduct = _spin(0.0, 1.0, 0.01, 0.3)
	_labeled(grid, "Conduct", _conduct)

	_temp_high = _spin(0.0, 4000.0, 1.0, 0.0)
	_labeled(grid, "Temp high", _temp_high)
	_state_high = LineEdit.new()
	_state_high.placeholder_text = "becomes above"
	_labeled(grid, "→ high", _state_high)
	_temp_low = _spin(0.0, 4000.0, 1.0, 0.0)
	_labeled(grid, "Temp low", _temp_low)
	_state_low = LineEdit.new()
	_state_low.placeholder_text = "becomes below"
	_labeled(grid, "→ low", _state_low)
	_life = _spin(0.0, 255.0, 1.0, 0.0)
	_labeled(grid, "Life ticks", _life)
	_life_into = LineEdit.new()
	_life_into.placeholder_text = "air"
	_labeled(grid, "→ decays", _life_into)

	root.add_child(_make_label("Reactions  (partner / self→ / partner→ / chance / ΔT / 1-way)"))
	_reaction_rows = VBoxContainer.new()
	root.add_child(_reaction_rows)
	var add_reaction := Button.new()
	add_reaction.text = "+ reaction"
	add_reaction.pressed.connect(func() -> void: _add_reaction_row())
	root.add_child(add_reaction)

	root.add_child(_make_label("Behavior ops  (op / offset / elem A / elem B / chance / symmetry)"))
	_op_rows = VBoxContainer.new()
	root.add_child(_op_rows)
	var add_op := Button.new()
	add_op.text = "+ behavior op"
	add_op.pressed.connect(func() -> void: _add_op_row())
	root.add_child(add_op)

	root.add_child(_make_label("Custom GLSL (must define ca_tick; CA_SELF = own id)"))
	_glsl_edit = TextEdit.new()
	_glsl_edit.custom_minimum_size = Vector2(0, 140)
	root.add_child(_glsl_edit)

	var apply := Button.new()
	apply.text = "Apply (create or update)"
	apply.pressed.connect(_on_apply)
	root.add_child(apply)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_status)


func _make_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _add_reaction_row(partner := "", self_b := "", partner_b := "", chance := 0.1,
		temp_delta := 0.0, oneway := false) -> void:
	var row := HBoxContainer.new()
	var p := LineEdit.new(); p.text = partner; p.placeholder_text = "partner"; p.custom_minimum_size.x = 76
	var sb := LineEdit.new(); sb.text = self_b; sb.placeholder_text = "keep"; sb.custom_minimum_size.x = 66
	var pb := LineEdit.new(); pb.text = partner_b; pb.placeholder_text = "keep"; pb.custom_minimum_size.x = 66
	var ch := _spin(0.0, 1.0, 0.001, chance, 64.0)
	var dt := _spin(-2000.0, 2000.0, 10.0, temp_delta, 64.0)
	var ow := CheckBox.new(); ow.button_pressed = oneway; ow.tooltip_text = "one-way"
	var rm := Button.new(); rm.text = "✕"
	rm.pressed.connect(func() -> void: row.queue_free())
	for c: Control in [p, sb, pb, ch, dt, ow, rm]:
		row.add_child(c)
	_reaction_rows.add_child(row)


func _add_op_row(opcode := 5, offset := Vector3i(0, 1, 0), elem_a := "", elem_b := "",
		chance := 0.1, symmetry := 0) -> void:
	var row := HBoxContainer.new()
	var op := OptionButton.new()
	for n in OP_NAMES:
		op.add_item(n)
	op.select(opcode)
	var x := _spin(-1, 1, 1, offset.x, 44.0)
	var y := _spin(-1, 1, 1, offset.y, 44.0)
	var z := _spin(-1, 1, 1, offset.z, 44.0)
	var a := LineEdit.new(); a.text = elem_a; a.placeholder_text = "any"; a.custom_minimum_size.x = 62
	var b := LineEdit.new(); b.text = elem_b; b.placeholder_text = "-"; b.custom_minimum_size.x = 62
	var ch := _spin(0.0, 1.0, 0.001, chance, 60.0)
	var sym := OptionButton.new()
	for n in SYM_NAMES:
		sym.add_item(n)
	sym.select(symmetry)
	var rm := Button.new(); rm.text = "✕"
	rm.pressed.connect(func() -> void: row.queue_free())
	for c: Control in [op, x, y, z, a, b, ch, sym, rm]:
		row.add_child(c)
	_op_rows.add_child(row)


# -------------------------------------------------- load / apply

func _refresh_load_picker() -> void:
	if _load_picker == null or world == null or world.element_set == null:
		return
	_load_picker.clear()
	_load_picker.add_item("(new element)")
	for id in world.element_set.get_element_count():
		var e = world.element_set.get_element(id)
		if e != null and e.element_name != "":
			_load_picker.add_item("%d: %s" % [id, e.element_name])


func _on_load_selected(index: int) -> void:
	for row in _reaction_rows.get_children():
		row.queue_free()
	for row in _op_rows.get_children():
		row.queue_free()
	if index <= 0:
		_name_edit.text = ""
		_glsl_edit.text = ""
		_status.text = ""
		return
	var id := int(_load_picker.get_item_text(index).split(":")[0])
	var e = world.element_set.get_element(id)
	if e == null:
		return
	_name_edit.text = e.element_name
	_class_picker.select(e.movement_class)
	_color_picker.color = e.base_color
	_density.value = e.density
	_flow.value = e.flow
	_emission.value = e.emission
	_initial_temp.value = e.initial_temp
	_conduct.value = e.heat_conduct
	_temp_high.value = e.temp_high
	_state_high.text = e.state_high
	_temp_low.value = e.temp_low
	_state_low.text = e.state_low
	_life.value = e.life
	_life_into.text = e.life_into
	for r in e.reactions:
		_add_reaction_row(r.partner, r.self_becomes, r.partner_becomes, r.chance, r.temp_delta, r.oneway)
	for o in e.behavior:
		_add_op_row(o.opcode, o.offset, o.element_a, o.element_b, o.chance, o.symmetry)
	_glsl_edit.text = e.custom_glsl
	_status.text = "loaded '%s'" % e.element_name


func _on_apply() -> void:
	var element_name := _name_edit.text.strip_edges()
	if element_name.is_empty():
		_status.text = "Give the element a name first."
		return

	var e := VoxelElement.new()
	e.element_name = element_name
	e.movement_class = _class_picker.selected
	e.base_color = _color_picker.color
	e.density = _density.value
	e.flow = _flow.value
	e.emission = _emission.value
	e.initial_temp = _initial_temp.value
	e.heat_conduct = _conduct.value
	e.temp_high = _temp_high.value
	e.state_high = _state_high.text.strip_edges()
	e.temp_low = _temp_low.value
	e.state_low = _state_low.text.strip_edges()
	e.life = int(_life.value)
	e.life_into = _life_into.text.strip_edges()
	e.custom_glsl = _glsl_edit.text

	for row in _reaction_rows.get_children():
		if row.is_queued_for_deletion():
			continue
		var c := row.get_children()
		var r := e.add_reaction(c[0].text.strip_edges(), c[1].text.strip_edges(),
			c[2].text.strip_edges(), c[3].value)
		r.temp_delta = c[4].value
		r.oneway = c[5].button_pressed

	for row in _op_rows.get_children():
		if row.is_queued_for_deletion():
			continue
		var c := row.get_children()
		if c[0].selected == 0:
			continue # None
		e.add_behavior_op(c[0].selected, Vector3i(int(c[1].value), int(c[2].value), int(c[3].value)),
			c[4].text.strip_edges(), c[5].text.strip_edges(), c[6].value, c[7].selected)

	var id: int = world.element_set.add_element(e)
	if id < 0:
		_status.text = "Failed to add element (set full?)."
		return
	_status.text = "Applied '%s' as id %d — select it in the palette and paint." % [element_name, id]
	_refresh_load_picker()
