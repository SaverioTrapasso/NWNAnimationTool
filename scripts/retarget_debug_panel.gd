extends Panel

## The single panel for configuring a prefab's bone map: an editable table
## (NWN node | associated bone, picked from a dropdown | rotation offset |
## live delta), PLUS the visual aid — Import a source glb to see it as a red
## stick-figure next to the blue-tinted NWN mesh, and click matching joints
## to fill in a row instead of hunting through the dropdown. Saves straight
## back to the .cfg file. main.gd owns the actual 3D visualizers/rig tinting
## and the click-pairing logic; this panel is the UI shell.

signal import_source_requested(path: String)
signal exit_requested()
signal save_requested()
signal save_as_chosen(path: String)

@onready var import_button: Button = $HeaderRow/ImportButton
@onready var exit_button: Button = $HeaderRow/ExitButton
@onready var save_config_button: Button = $HeaderRow/SaveConfigButton
@onready var close_button: Button = $HeaderRow/CloseButton
@onready var import_dialog: FileDialog = $ImportDialog
@onready var save_as_dialog: FileDialog = $SaveAsDialog
@onready var instructions_label: Label = $InstructionsLabel
@onready var rows_container: VBoxContainer = $Scroll/Rows
@onready var status_label: Label = $StatusLabel

var _bone_options: Dictionary = {} # nwn_node_name -> OptionButton
var _rot_offset_spins: Dictionary = {} # nwn_node_name -> [SpinBox x, y, z]
var _delta_labels: Dictionary = {} # nwn_node_name -> Label
var _available_bones: Array = [] # source bone names, populated after Import

func _ready() -> void:
	visible = false
	import_button.pressed.connect(func(): import_dialog.popup_centered_ratio(0.6))
	import_dialog.file_selected.connect(func(path): import_source_requested.emit(path))
	exit_button.pressed.connect(func(): exit_requested.emit())
	close_button.pressed.connect(func(): exit_requested.emit())
	save_config_button.pressed.connect(func(): save_requested.emit())
	save_as_dialog.file_selected.connect(func(path): save_as_chosen.emit(path))

func prompt_save_as() -> void:
	save_as_dialog.popup_centered_ratio(0.6)

## node_names: the fixed list of NWN nodes to show as rows (always the same,
## regardless of whether a config is loaded yet); bone_map/rotation_offsets
## supply each row's current value, if any.
func set_bone_map(node_names: Array, bone_map: Dictionary, rotation_offsets: Dictionary) -> void:
	for child in rows_container.get_children():
		child.queue_free()
	_bone_options.clear()
	_rot_offset_spins.clear()
	_delta_labels.clear()

	for nwn_name in node_names:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)

		var nwn_label := Label.new()
		nwn_label.text = nwn_name
		nwn_label.custom_minimum_size = Vector2(110, 0)
		row.add_child(nwn_label)

		var option := OptionButton.new()
		option.custom_minimum_size = Vector2(130, 0)
		row.add_child(option)
		_bone_options[nwn_name] = option
		_set_option_items(option, _available_bones, String(bone_map.get(nwn_name, "")))

		var rot_row := HBoxContainer.new()
		rot_row.custom_minimum_size = Vector2(180, 0)
		rot_row.add_theme_constant_override("separation", 2)
		var offset: Vector3 = rotation_offsets.get(nwn_name, Vector3.ZERO)
		var spins: Array = []
		for axis_i in range(3):
			var spin := SpinBox.new()
			spin.custom_minimum_size = Vector2(58, 0)
			spin.min_value = -360.0
			spin.max_value = 360.0
			spin.step = 1.0
			spin.allow_greater = true
			spin.allow_lesser = true
			spin.prefix = ["X", "Y", "Z"][axis_i]
			spin.value = offset[axis_i]
			rot_row.add_child(spin)
			spins.append(spin)
		row.add_child(rot_row)
		_rot_offset_spins[nwn_name] = spins

		var delta_label := Label.new()
		delta_label.text = "—"
		delta_label.custom_minimum_size = Vector2(60, 0)
		row.add_child(delta_label)
		_delta_labels[nwn_name] = delta_label

		rows_container.add_child(row)

## Called once a source rig is imported: fills every row's dropdown with the
## actual bone names from that file, keeping each row's current value
## selected if present (or appended, if it came from the .cfg but isn't in
## this particular source — e.g. configured against a different file before).
func set_available_bones(names: Array) -> void:
	_available_bones = names
	for nwn_name in _bone_options.keys():
		var option: OptionButton = _bone_options[nwn_name]
		var current := _selected_text(option)
		_set_option_items(option, names, current)

func _set_option_items(option: OptionButton, names: Array, selected_value: String) -> void:
	option.clear()
	option.add_item("") # allow "unmapped"
	for n in names:
		option.add_item(n)
	if selected_value != "":
		var idx := names.find(selected_value)
		if idx == -1:
			option.add_item(selected_value)
			idx = option.item_count - 1
		else:
			idx += 1 # account for the leading blank item
		option.select(idx)
	else:
		option.select(0)

func _selected_text(option: OptionButton) -> String:
	if option.selected < 0:
		return ""
	return option.get_item_text(option.selected)

## Reads the associated-bone dropdowns as currently selected.
func get_bone_map() -> Dictionary:
	var result := {}
	for nwn_name in _bone_options.keys():
		result[nwn_name] = _selected_text(_bone_options[nwn_name])
	return result

## Reads the per-bone rotation offset fields as currently edited (degrees).
func get_rotation_offsets() -> Dictionary:
	var result := {}
	for nwn_name in _rot_offset_spins.keys():
		var spins: Array = _rot_offset_spins[nwn_name]
		result[nwn_name] = Vector3(spins[0].value, spins[1].value, spins[2].value)
	return result

## Selects this value in that row's dropdown — used by the visual
## click-to-pick flow, so clicking a pair of joints fills the same table you
## can also edit by hand.
func set_ff14_value(nwn_name: String, value: String) -> void:
	if _bone_options.has(nwn_name):
		_set_option_items(_bone_options[nwn_name], _available_bones, value)

## degrees = INF means "not found" (bone missing in source, or NWN node not
## found in the rig) — shown as "n/a" instead of a number.
func set_delta(nwn_node_name: String, degrees: float) -> void:
	if not _delta_labels.has(nwn_node_name):
		return
	var label: Label = _delta_labels[nwn_node_name]
	label.text = "n/a" if is_inf(degrees) else "%.1f°" % degrees

func set_status(text: String) -> void:
	status_label.text = text

func show_panel() -> void:
	visible = true

func hide_panel() -> void:
	visible = false

func toggle_visible() -> void:
	visible = not visible
