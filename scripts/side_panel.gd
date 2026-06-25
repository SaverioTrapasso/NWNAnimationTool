extends Control

signal reset_pressed()
signal pole_vectors_toggled(show_all: bool)
signal save_file_requested(path: String, anim_name: String)
signal open_file_requested(path: String)
signal save_to_timeline_requested()
signal duration_changed(value: float)
signal undo_requested()
signal focus_requested()
signal play_toggled(playing: bool)

@export var rig_root: Node3D

@onready var name_edit: LineEdit = $Panel/VBoxContainer/AnimNameEdit
@onready var duration_edit: SpinBox = $Panel/VBoxContainer/DurationSpinBox
@onready var save_button: Button = $Panel/VBoxContainer/SaveButton
@onready var open_button: Button = $Panel/VBoxContainer/OpenButton
@onready var reset_button: Button = $Panel/VBoxContainer/ResetButton
@onready var undo_button: Button = $Panel/VBoxContainer/UndoFocusRow/UndoButton
@onready var focus_button: Button = $Panel/VBoxContainer/UndoFocusRow/FocusButton
@onready var save_to_timeline_button: Button = $Panel/VBoxContainer/SaveToTimelineButton
@onready var play_button: Button = $Panel/VBoxContainer/PlayButton
@onready var status_label: Label = $Panel/VBoxContainer/StatusLabel
@onready var save_dialog: FileDialog = $SaveDialog
@onready var open_dialog: FileDialog = $OpenDialog
@onready var cloak_button: Button = $Panel/VBoxContainer/CloakToggleButton
@onready var right_hand_weapon_button: Button = $Panel/VBoxContainer/RightHandWeaponButton
@onready var left_hand_weapon_button: Button = $Panel/VBoxContainer/LeftHandWeaponButton
@onready var pole_vectors_button: Button = $Panel/VBoxContainer/PoleVectorsToggleButton
@onready var timeline: Control = $Timeline
@onready var transform_panel: Panel = $TransformPanel

const CLOAK_TABARD_NODES := ["cloak_g", "belt_g1"]

var _weapon_meshes: Dictionary = {} # hand_node_name -> MeshInstance3D

func _ready() -> void:
	save_button.pressed.connect(_on_save_pressed)
	save_dialog.file_selected.connect(_on_save_file_selected)
	open_button.pressed.connect(_on_open_pressed)
	open_dialog.file_selected.connect(_on_open_file_selected)
	reset_button.pressed.connect(_on_reset_pressed)
	undo_button.pressed.connect(func(): undo_requested.emit())
	focus_button.pressed.connect(func(): focus_requested.emit())
	save_to_timeline_button.pressed.connect(_on_save_to_timeline_pressed)
	play_button.toggled.connect(_on_play_toggled)
	duration_edit.value_changed.connect(_on_duration_changed)
	cloak_button.toggled.connect(_on_cloak_toggled)
	right_hand_weapon_button.toggled.connect(_on_weapon_toggled.bind("rhand_g", Color(0.2, 0.9, 1.0)))
	left_hand_weapon_button.toggled.connect(_on_weapon_toggled.bind("lhand_g", Color(1.0, 0.2, 0.2)))
	pole_vectors_button.toggled.connect(_on_pole_vectors_toggled)

func set_status(text: String) -> void:
	status_label.text = text

func get_anim_name() -> String:
	return name_edit.text.strip_edges()

func set_anim_name(value: String) -> void:
	name_edit.text = value

func set_duration(value: float) -> void:
	duration_edit.set_value_no_signal(value)
	timeline.set_length(value)

func _on_save_pressed() -> void:
	var anim_name := get_anim_name()
	if anim_name.is_empty():
		status_label.text = "Please enter an animation name."
		return
	save_dialog.current_file = "%s.txt" % anim_name
	save_dialog.popup_centered_ratio(0.6)

func _on_save_file_selected(path: String) -> void:
	save_file_requested.emit(path, get_anim_name())

func _on_open_pressed() -> void:
	open_dialog.popup_centered_ratio(0.6)

func _on_open_file_selected(path: String) -> void:
	open_file_requested.emit(path)

func _on_reset_pressed() -> void:
	reset_pressed.emit()
	status_label.text = "Pose reset."

func _on_save_to_timeline_pressed() -> void:
	save_to_timeline_requested.emit()

func _on_play_toggled(pressed: bool) -> void:
	play_button.text = "Pause" if pressed else "Play"
	play_toggled.emit(pressed)

## Lets main.gd reset the button's visual state (e.g. when the user manually
## scrubs the timeline mid-playback, which pauses it) without re-emitting
## play_toggled and causing a feedback loop.
func set_playing(playing: bool) -> void:
	play_button.set_pressed_no_signal(playing)
	play_button.text = "Pause" if playing else "Play"

func _on_duration_changed(value: float) -> void:
	timeline.set_length(value)
	duration_changed.emit(value)

func _on_pole_vectors_toggled(pressed: bool) -> void:
	pole_vectors_toggled.emit(pressed)

## Pressed (toggled on) = hidden, since the button reads "Hide cloak/tabard".
func _on_cloak_toggled(pressed: bool) -> void:
	for node_name in CLOAK_TABARD_NODES:
		var node := _find(rig_root, node_name)
		if node != null:
			node.visible = not pressed

func _on_weapon_toggled(pressed: bool, hand_node_name: String, color: Color) -> void:
	if pressed:
		_add_weapon(hand_node_name, color)
	elif _weapon_meshes.has(hand_node_name):
		_weapon_meshes[hand_node_name].queue_free()
		_weapon_meshes.erase(hand_node_name)

func _add_weapon(hand_node_name: String, color: Color) -> void:
	var hand := _find(rig_root, hand_node_name)
	if hand == null:
		return
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.015
	mesh.bottom_radius = 0.015
	mesh.height = 0.6

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 1.5

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.rotation_degrees = Vector3(-90, 0, 0)
	# CylinderMesh is centered on its own pivot; shift it by half its height
	# along the (now rotated) blade axis so the hand grips the near END of
	# the blade, not its middle, with the grip sitting right at the hand.
	# The small extra downward nudge moves the grip from the wrist joint
	# into the fist, where it visually belongs.
	mi.position = Vector3(0, -0.06, -mesh.height * 0.5)
	hand.add_child(mi)
	_weapon_meshes[hand_node_name] = mi

func _find(node: Node, target_name: String) -> Node3D:
	if node == null:
		return null
	if node.name == target_name and node is Node3D:
		return node
	for child in node.get_children():
		var found := _find(child, target_name)
		if found != null:
			return found
	return null
