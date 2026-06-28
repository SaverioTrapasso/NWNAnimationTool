extends Panel

## Bone configuration panel: maps each NWN node to a source bone name from
## the currently loaded retarget animation. Opened/closed by the sidebar's
## "Bone configuration" button (side_panel.gd owns that button and the
## show/hide toggle); this panel is just the table + load/save config UI.
## Rotation offsets are no longer typed here — Bake derives them
## automatically from how you've posed the rig to match the overlay.

signal cfg_import_requested(path: String)
signal save_requested()
signal save_as_chosen(path: String)
signal root_scale_changed(value: float)

@onready var close_button: Button = $TitleRow/CloseButton
@onready var root_scale_spin: SpinBox = $ScaleRow/RootScaleSpin
@onready var cfg_button: Button = $ConfigRow/CfgButton
@onready var save_config_button: Button = $ConfigRow/SaveConfigButton
@onready var cfg_dialog: FileDialog = $CfgDialog
@onready var save_as_dialog: FileDialog = $SaveAsDialog
@onready var rows_container: VBoxContainer = $Scroll/Rows
@onready var status_label: Label = $StatusLabel

var _bone_options: Dictionary = {} # nwn_node_name -> OptionButton
var _available_bones: Array = [] # source bone names, populated after Load animation

func _ready() -> void:
	visible = false
	close_button.pressed.connect(func(): hide_panel())
	cfg_button.pressed.connect(func(): cfg_dialog.popup_centered_ratio(0.6))
	cfg_dialog.file_selected.connect(func(path): cfg_import_requested.emit(path))
	save_config_button.pressed.connect(func(): save_requested.emit())
	save_as_dialog.file_selected.connect(func(path): save_as_chosen.emit(path))
	root_scale_spin.value_changed.connect(func(v): root_scale_changed.emit(v))

## Always shown on "Save config" so the user explicitly picks the filename
## and location every time, rather than silently overwriting whatever .cfg
## happened to be loaded — pre-filled with the current path, if any.
func prompt_save_as(current_path: String = "") -> void:
	if current_path != "":
		save_as_dialog.current_dir = current_path.get_base_dir()
		save_as_dialog.current_file = current_path.get_file()
	save_as_dialog.popup_centered_ratio(0.6)

func get_root_scale() -> float:
	return root_scale_spin.value

func set_root_scale(value: float) -> void:
	root_scale_spin.value = value

## node_names: the fixed list of NWN nodes to show as rows (always the same,
## regardless of whether a config is loaded yet); bone_map supplies each
## row's current value, if any.
func set_bone_map(node_names: Array, bone_map: Dictionary) -> void:
	for child in rows_container.get_children():
		child.queue_free()
	_bone_options.clear()

	for nwn_name in node_names:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)

		var nwn_label := Label.new()
		nwn_label.text = nwn_name
		nwn_label.custom_minimum_size = Vector2(100, 0)
		row.add_child(nwn_label)

		var option := OptionButton.new()
		option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(option)
		_bone_options[nwn_name] = option
		_set_option_items(option, _available_bones, String(bone_map.get(nwn_name, "")))

		rows_container.add_child(row)

## Called once a source rig is loaded: fills every row's dropdown with the
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

func set_status(text: String) -> void:
	status_label.text = text

func show_panel() -> void:
	visible = true

func hide_panel() -> void:
	visible = false

func toggle_visible() -> void:
	visible = not visible
