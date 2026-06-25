extends Control

signal reset_pressed()
signal pole_vectors_toggled(show_all: bool)

@export var rig_root: Node3D

@onready var name_edit: LineEdit = $Panel/VBoxContainer/AnimNameEdit
@onready var save_button: Button = $Panel/VBoxContainer/SaveButton
@onready var reset_button: Button = $Panel/VBoxContainer/ResetButton
@onready var status_label: Label = $Panel/VBoxContainer/StatusLabel
@onready var save_dialog: FileDialog = $SaveDialog
@onready var cloak_button: Button = $TopRightButtons/CloakToggleButton
@onready var weapons_button: Button = $TopRightButtons/WeaponsToggleButton
@onready var pole_vectors_button: Button = $TopRightButtons/PoleVectorsToggleButton

const CLOAK_TABARD_NODES := ["cloak_g", "belt_g1"]
const WEAPON_HAND_NODES := {
	"rhand_g": Color(0.2, 0.9, 1.0),
	"lhand_g": Color(1.0, 0.2, 0.2),
}

var _weapon_meshes: Array[MeshInstance3D] = []

func _ready() -> void:
	save_button.pressed.connect(_on_save_pressed)
	save_dialog.file_selected.connect(_on_file_selected)
	reset_button.pressed.connect(_on_reset_pressed)
	cloak_button.toggled.connect(_on_cloak_toggled)
	weapons_button.toggled.connect(_on_weapons_toggled)
	pole_vectors_button.toggled.connect(_on_pole_vectors_toggled)

func _on_save_pressed() -> void:
	var anim_name := name_edit.text.strip_edges()
	if anim_name.is_empty():
		status_label.text = "Please enter an animation name."
		return
	save_dialog.current_file = "%s.txt" % anim_name
	save_dialog.popup_centered_ratio(0.6)

func _on_file_selected(path: String) -> void:
	var anim_name := name_edit.text.strip_edges()
	var content := MdlExporter.export_pose(rig_root, anim_name)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		status_label.text = "Error: could not write file."
		return
	file.store_string(content)
	file.close()
	status_label.text = "Saved: %s" % path

func _on_reset_pressed() -> void:
	reset_pressed.emit()
	status_label.text = "Pose reset."

func _on_pole_vectors_toggled(pressed: bool) -> void:
	pole_vectors_toggled.emit(pressed)

## Pressed (toggled on) = hidden, since the button reads "Hide cloak/tabard".
func _on_cloak_toggled(pressed: bool) -> void:
	for node_name in CLOAK_TABARD_NODES:
		var node := _find(rig_root, node_name)
		if node != null:
			node.visible = not pressed

func _on_weapons_toggled(pressed: bool) -> void:
	if pressed:
		for hand_name in WEAPON_HAND_NODES.keys():
			_add_weapon(hand_name, WEAPON_HAND_NODES[hand_name])
	else:
		for mesh in _weapon_meshes:
			mesh.queue_free()
		_weapon_meshes.clear()

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
	_weapon_meshes.append(mi)

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
