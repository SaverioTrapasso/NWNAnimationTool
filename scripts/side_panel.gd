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
signal copy_key_requested()
signal paste_key_requested()
signal remove_key_requested()
signal new_requested()
signal retarget_load_animation_requested(path: String)
signal retarget_bake_requested()
signal retarget_overlay_toggled(enabled: bool)
signal gender_selected(model_path: String)

@export var rig_root: Node3D
@export var rig_controller: Node3D

@onready var _sidebar: Control = $Sidebar/Scroll/Margin/Sections

@onready var new_button: Button = $TopBar/Margin/Row/NewButton
@onready var open_button: Button = $TopBar/Margin/Row/OpenButton
@onready var save_button: Button = $TopBar/Margin/Row/SaveButton
@onready var male_button: Button = $TopBar/GenderRow/MarginRight/Row/MaleButton
@onready var female_button: Button = $TopBar/GenderRow/MarginRight/Row/FemaleButton
@onready var new_confirm_dialog: ConfirmationDialog = $NewConfirmDialog
@onready var save_dialog: FileDialog = $SaveDialog
@onready var open_dialog: FileDialog = $OpenDialog

@onready var reset_button: Button = _sidebar.get_node("Tools/ResetButton")

@onready var load_animation_button: Button = _sidebar.get_node("Retarget/LoadAnimationButton")
@onready var bone_config_button: Button = _sidebar.get_node("Retarget/BoneConfigButton")
@onready var bake_button: Button = _sidebar.get_node("Retarget/BakeButton")
@onready var load_animation_dialog: FileDialog = $LoadAnimationDialog
@onready var bone_config_panel: Panel = $BoneConfigPanel

@onready var name_edit: LineEdit = _sidebar.get_node("AnimationInfo/AnimNameEdit")
@onready var duration_edit: SpinBox = _sidebar.get_node("AnimationInfo/DurationSpinBox")

@onready var save_to_timeline_button: Button = _sidebar.get_node("Keyframe/KeyframeGrid/SetButton")
@onready var copy_key_button: Button = _sidebar.get_node("Keyframe/KeyframeGrid/CopyKeyButton")
@onready var paste_key_button: Button = _sidebar.get_node("Keyframe/KeyframeGrid/PasteKeyButton")
@onready var remove_key_button: Button = _sidebar.get_node("Keyframe/KeyframeGrid/RemoveKeyButton")

@onready var status_label: Label = $Sidebar/StatusLabel

@onready var viewport_toolbar: Control = $ViewportToolbar
@onready var undo_button: Button = viewport_toolbar.get_node("UndoButton")
@onready var focus_button: Button = viewport_toolbar.get_node("FocusButton")
@onready var cloak_button: Button = viewport_toolbar.get_node("CloakToggleButton")
@onready var right_hand_weapon_button: Button = viewport_toolbar.get_node("RightHandWeaponButton")
@onready var left_hand_weapon_button: Button = viewport_toolbar.get_node("LeftHandWeaponButton")
@onready var left_shield_button: Button = viewport_toolbar.get_node("LeftShieldButton")
@onready var pole_vectors_button: Button = viewport_toolbar.get_node("PoleVectorsToggleButton")
@onready var skeleton_overlay_button: Button = viewport_toolbar.get_node("SkeletonOverlayButton")

@onready var play_button: Button = _sidebar.get_node("Keyframe/PlayButton")
@onready var timeline: Control = $TimelineRow/Timeline
@onready var transform_panel: Panel = $TransformPanel

## The female model (a_fa.glb) names its cloak mesh "Cloak_g" (capital C)
## instead of the male model's "cloak_g" -- both are listed so the hide
## toggle works regardless of which model is currently loaded.
const CLOAK_TABARD_NODES := ["cloak_g", "Cloak_g", "belt_g1"]
const MALE_MODEL_PATH := "res://assets/nwn/a_ba.glb"
const FEMALE_MODEL_PATH := "res://assets/nwn/a_fa.glb"

var _weapon_meshes: Dictionary = {} # hand_node_name -> MeshInstance3D

func _ready() -> void:
	new_button.pressed.connect(func(): new_confirm_dialog.popup_centered())
	new_confirm_dialog.confirmed.connect(func(): new_requested.emit())
	save_button.pressed.connect(_on_save_pressed)
	save_dialog.file_selected.connect(_on_save_file_selected)
	open_button.pressed.connect(_on_open_pressed)
	open_dialog.file_selected.connect(_on_open_file_selected)
	reset_button.pressed.connect(_on_reset_pressed)
	undo_button.pressed.connect(func(): undo_requested.emit())
	focus_button.pressed.connect(func(): focus_requested.emit())
	save_to_timeline_button.pressed.connect(_on_save_to_timeline_pressed)
	copy_key_button.pressed.connect(func(): copy_key_requested.emit())
	paste_key_button.pressed.connect(func(): paste_key_requested.emit())
	remove_key_button.pressed.connect(func(): remove_key_requested.emit())
	play_button.toggled.connect(_on_play_toggled)
	duration_edit.value_changed.connect(_on_duration_changed)
	cloak_button.toggled.connect(_on_cloak_toggled)
	male_button.pressed.connect(func(): _on_gender_button_pressed(MALE_MODEL_PATH))
	female_button.pressed.connect(func(): _on_gender_button_pressed(FEMALE_MODEL_PATH))
	right_hand_weapon_button.toggled.connect(_on_weapon_toggled.bind("rhand", "right_weapon", Color(0.2, 0.9, 1.0)))
	left_hand_weapon_button.toggled.connect(_on_weapon_toggled.bind("lhand", "left_weapon", Color(1.0, 0.2, 0.2)))
	left_shield_button.toggled.connect(_on_weapon_toggled.bind("lforearm", "shield", Color(0.5, 1.0, 0.3)))
	pole_vectors_button.toggled.connect(_on_pole_vectors_toggled)
	skeleton_overlay_button.toggled.connect(func(v): retarget_overlay_toggled.emit(v))

	load_animation_button.pressed.connect(func(): load_animation_dialog.popup_centered_ratio(0.6))
	load_animation_dialog.file_selected.connect(func(path): retarget_load_animation_requested.emit(path))
	bone_config_button.pressed.connect(func(): bone_config_panel.toggle_visible())
	bake_button.pressed.connect(func(): retarget_bake_requested.emit())

func set_status(text: String) -> void:
	status_label.text = text

## Used by "New": untoggles any active display toggle, which naturally
## triggers their existing handlers to undo the effect (remove weapon
## meshes, hide pole vectors, hide the retarget overlay). The cloak toggle
## is the odd one out: its neutral/default state is HIDDEN, not shown, so
## it's reset to pressed=true instead of being lumped in with the others.
func reset_display_toggles() -> void:
	for button in [right_hand_weapon_button, left_hand_weapon_button, left_shield_button, pole_vectors_button, skeleton_overlay_button, play_button]:
		if button.button_pressed:
			button.button_pressed = false
	if not cloak_button.button_pressed:
		cloak_button.button_pressed = true

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
		status_label.text = "Enter an animation name."
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

## Pressed (toggled on) = hidden, since the button means "hide cloak/tabard".
func _on_cloak_toggled(pressed: bool) -> void:
	for node_name in CLOAK_TABARD_NODES:
		var node := _find(rig_root, node_name)
		if node != null:
			node.visible = not pressed

## rig_root is only assigned by main.gd after this panel's own _ready() has
## already run, so the scene's button_pressed=true default can't apply the
## actual hide-on-load effect by itself -- main.gd calls this once rig_root
## is set, to make "hidden by default" real (most poses don't touch the
## cloak, so starting with it shown just gets in the way).
func apply_initial_cloak_state() -> void:
	_on_cloak_toggled(cloak_button.button_pressed)

func _on_gender_button_pressed(model_path: String) -> void:
	gender_selected.emit(model_path)

## Lets main.gd reflect which model is actually loaded (e.g. after a swap
## succeeds) by disabling that side's button -- a simple, dependency-free
## way to show which one is active without wiring up a ButtonGroup resource.
func set_active_gender(model_path: String) -> void:
	male_button.disabled = (model_path == MALE_MODEL_PATH)
	female_button.disabled = (model_path == FEMALE_MODEL_PATH)

## attach_node_name is the weapon/shield-attachment dummy ("rhand"/"lhand"/
## "lforearm"), not the hand/forearm mesh itself -- the preview is parented
## there so it rotates along with that dummy, and (since it's hard to click
## a collider buried inside the limb) the preview mesh doubles as the actual
## pick target for the matching component while it's visible.
func _on_weapon_toggled(pressed: bool, attach_node_name: String, component_id: String, color: Color) -> void:
	if pressed:
		_add_weapon(attach_node_name, component_id, color)
	elif _weapon_meshes.has(attach_node_name):
		if is_instance_valid(_weapon_meshes[attach_node_name]):
			_weapon_meshes[attach_node_name].queue_free()
		_weapon_meshes.erase(attach_node_name)
		if rig_controller != null:
			rig_controller.reset_component_pick(component_id, attach_node_name)

func _add_weapon(hand_node_name: String, component_id: String, color: Color) -> void:
	var hand := _find(rig_root, hand_node_name)
	if hand == null:
		return
	var mesh := CylinderMesh.new()
	var mi := MeshInstance3D.new()

	if component_id == "shield":
		# A shield reads as a short, wide disc rather than a blade: a much
		# bigger radius (>= 10x the weapon's) squashed down to a fraction of
		# the weapon's height, rotated 90° so its flat face points outward
		# from the forearm instead of running along it like a cylinder grip.
		mesh.top_radius = 0.15
		mesh.bottom_radius = 0.15
		mesh.height = 0.05
		mi.rotation_degrees = Vector3(0, 0, 90)
		mi.position = Vector3.ZERO
	else:
		mesh.top_radius = 0.015
		mesh.bottom_radius = 0.015
		mesh.height = 0.6
		mi.rotation_degrees = Vector3(-90, 0, 0)
		# CylinderMesh is centered on its own pivot; shift it by half its
		# height along the (now rotated) blade axis so the hand grips the
		# near END of the blade, not its middle, with the grip sitting right
		# at the hand. The small extra downward nudge moves the grip from
		# the wrist joint into the fist, where it visually belongs.
		mi.position = Vector3(0, -0.06, -mesh.height * 0.5)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 1.5

	mi.mesh = mesh
	mi.material_override = mat
	hand.add_child(mi)
	_weapon_meshes[hand_node_name] = mi
	if rig_controller != null:
		rig_controller.set_component_pick_mesh(component_id, hand_node_name, mi)

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
