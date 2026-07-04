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
## Single reference-skeleton toggle: main.gd routes it to the red (glb) or
## green (AI) visualizer depending on which motion source is active.
signal overlay_toggled(enabled: bool)
signal gender_selected(model_path: String)
signal pose_memory_save_requested(slot: int)
signal pose_memory_load_requested(slot: int)
signal ai_pose_image_selected(path: String)
signal ai_pose_apply_requested()
signal ai_ground_toggled(enabled: bool)
## Emitted when the user edits any SOURCE TRANSFORM control; kind is
## "image", "video" or "glb". Same manual-adjustment language in all three
## motion-source wizards: rotate/offset the reference skeleton until it
## matches, then Apply/Bake picks the transform up automatically.
signal source_xform_changed(kind: String)
signal ai_bulk_requested(input_dir: String, output_dir: String)
signal video_pose_open_requested()

@export var rig_root: Node3D
@export var rig_controller: Node3D

@onready var _sidebar: Control = $Sidebar/Scroll/Margin/Sections

@onready var file_menu: MenuButton = $TopBar/Margin/Row/FileMenu
@onready var utility_menu: MenuButton = $TopBar/Margin/Row/UtilityMenu
@onready var header_name_label: Label = $TopBar/HeaderNameLabel
@onready var male_button: Button = $ViewportToolbar/MaleButton
@onready var female_button: Button = $ViewportToolbar/FemaleButton
@onready var new_confirm_dialog: ConfirmationDialog = $NewConfirmDialog
@onready var save_dialog: FileDialog = $SaveDialog
@onready var open_dialog: FileDialog = $OpenDialog

@onready var reset_button: Button = _sidebar.get_node("Keyframe/ResetButton")

@onready var bake_button: Button = $BoneConfigPanel/ConfigRow/BakeButton
@onready var load_animation_dialog: FileDialog = $LoadAnimationDialog
@onready var bone_config_panel: Panel = $BoneConfigPanel

@onready var duration_edit: SpinBox = $TimelineRow/DurationBox/DurationSpinBox

## The animation name is set during the Save flow (derived from the chosen
## filename) and mirrored in the header label so it stays always visible.
var _anim_name: String = ""

@onready var save_to_timeline_button: Button = _sidebar.get_node("Keyframe/KeyframeGrid/SetButton")
@onready var copy_key_button: Button = _sidebar.get_node("Keyframe/KeyframeGrid/CopyKeyButton")
@onready var paste_key_button: Button = _sidebar.get_node("Keyframe/KeyframeGrid/PasteKeyButton")
@onready var remove_key_button: Button = _sidebar.get_node("Keyframe/KeyframeGrid/RemoveKeyButton")

@onready var status_label: Label = $Sidebar/StatusLabel

@onready var viewport_toolbar: Control = $ViewportToolbar
@onready var cloak_button: Button = viewport_toolbar.get_node("CloakToggleButton")
@onready var right_hand_weapon_button: Button = viewport_toolbar.get_node("RightHandWeaponButton")
@onready var left_hand_weapon_button: Button = viewport_toolbar.get_node("LeftHandWeaponButton")
@onready var left_shield_button: Button = viewport_toolbar.get_node("LeftShieldButton")
@onready var pole_vectors_button: Button = viewport_toolbar.get_node("PoleVectorsToggleButton")
@onready var overlay_button: Button = viewport_toolbar.get_node("SkeletonOverlayButton")

@onready var play_button: Button = _sidebar.get_node("Keyframe/PlayButton")
@onready var timeline: Control = $TimelineRow/Timeline
@onready var transform_panel: Panel = $TransformPanel

@onready var _pose_memory_load_buttons: Array[Button] = []

@onready var image_pose_panel: Panel = $ImagePosePanel
@onready var video_pose_panel: Panel = $VideoPosePanel
@onready var ai_load_image_button: Button = $ImagePosePanel/Body/ImageRow/BrowseButton
@onready var ai_apply_pose_button: Button = $ImagePosePanel/Body/ApplyPoseButton
@onready var ai_ground_check: CheckBox = $ImagePosePanel/Body/GroundCheck
@onready var ai_image_dialog: FileDialog = $AIImageDialog
@onready var ai_bulk_input_dialog: FileDialog = $BulkInputDialog
@onready var ai_bulk_output_dialog: FileDialog = $BulkOutputDialog
@onready var motion_config_panel: Panel = $MotionConfigPanel

## The female model (a_fa.glb) names its cloak mesh "Cloak_g" (capital C)
## instead of the male model's "cloak_g" -- both are listed so the hide
## toggle works regardless of which model is currently loaded.
const CLOAK_TABARD_NODES := ["cloak_g", "Cloak_g", "belt_g1"]
const MALE_MODEL_PATH := "res://assets/nwn/a_ba.glb"
const FEMALE_MODEL_PATH := "res://assets/nwn/a_fa.glb"

var _weapon_meshes: Dictionary = {} # hand_node_name -> MeshInstance3D

const FILE_ID_NEW := 0
const FILE_ID_OPEN := 1
const FILE_ID_SAVE := 2
const FILE_ID_UNDO := 3
const FILE_ID_FOCUS := 4

const UTIL_ID_IMAGE := 0
const UTIL_ID_VIDEO := 1
const UTIL_ID_GLB := 2
const UTIL_ID_BULK := 3

func _ready() -> void:
	var fm: PopupMenu = file_menu.get_popup()
	fm.add_item("New", FILE_ID_NEW)
	fm.add_item("Open...", FILE_ID_OPEN)
	fm.add_item("Save...", FILE_ID_SAVE)
	fm.add_separator()
	fm.add_item("Undo", FILE_ID_UNDO, KEY_MASK_CTRL | KEY_Z)
	fm.add_item("Focus selection", FILE_ID_FOCUS, KEY_F)
	fm.id_pressed.connect(_on_file_menu_pressed)

	var um: PopupMenu = utility_menu.get_popup()
	um.add_item("Pose from image...", UTIL_ID_IMAGE)
	um.add_item("Motion capture from video...", UTIL_ID_VIDEO)
	um.add_item("Import from 3D file...", UTIL_ID_GLB)
	um.add_separator()
	um.add_item("Bulk: image folder...", UTIL_ID_BULK)
	um.id_pressed.connect(_on_utility_menu_pressed)

	new_confirm_dialog.confirmed.connect(func(): new_requested.emit())
	save_dialog.file_selected.connect(_on_save_file_selected)
	open_dialog.file_selected.connect(_on_open_file_selected)
	reset_button.pressed.connect(_on_reset_pressed)
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
	overlay_button.toggled.connect(func(v): overlay_toggled.emit(v))

	# glb wizard: picking the file opens the Bone Config panel right away —
	# it IS the configure step of that flow, and Bake now lives inside it.
	load_animation_dialog.file_selected.connect(func(path):
		retarget_load_animation_requested.emit(path)
		bone_config_panel.visible = true)
	bake_button.pressed.connect(func(): retarget_bake_requested.emit())

	for i in 3:
		var slot_name := "Slot%d" % (i + 1)
		var save_btn: Button = _sidebar.get_node("PoseMemory/%s/SaveButton" % slot_name)
		var load_btn: Button = _sidebar.get_node("PoseMemory/%s/LoadButton" % slot_name)
		_pose_memory_load_buttons.append(load_btn)
		save_btn.pressed.connect(pose_memory_save_requested.emit.bind(i))
		load_btn.pressed.connect(pose_memory_load_requested.emit.bind(i))

	image_pose_panel.get_node("TitleRow/CloseButton").pressed.connect(func(): set_image_panel_open(false))
	image_pose_panel.get_node("Body/BulkButton").pressed.connect(func(): ai_bulk_input_dialog.popup_centered_ratio(0.6))
	ai_load_image_button.pressed.connect(func(): ai_image_dialog.popup_centered_ratio(0.6))
	ai_image_dialog.file_selected.connect(_on_ai_image_selected)
	ai_apply_pose_button.pressed.connect(func(): ai_pose_apply_requested.emit())
	ai_ground_check.toggled.connect(func(v): ai_ground_toggled.emit(v))

	# SOURCE TRANSFORM spins: same node names in every wizard, one wiring loop.
	for pair in [[image_pose_panel.get_node("Body"), "image"],
			[video_pose_panel.get_node("Body"), "video"],
			[bone_config_panel.get_node("XformRow"), "glb"]]:
		var container: Node = pair[0]
		var kind: String = pair[1]
		for spin in _source_xform_spins(container, kind):
			spin.value_changed.connect(func(_v): source_xform_changed.emit(kind))
	ai_bulk_input_dialog.dir_selected.connect(_on_bulk_input_selected)
	ai_bulk_output_dialog.dir_selected.connect(_on_bulk_output_selected)

func set_pose_memory_slot_filled(slot: int, filled: bool) -> void:
	if slot >= 0 and slot < _pose_memory_load_buttons.size():
		_pose_memory_load_buttons[slot].disabled = not filled

func set_status(text: String) -> void:
	status_label.text = text

## Used by "New": untoggles any active display toggle, which naturally
## triggers their existing handlers to undo the effect (remove weapon
## meshes, hide pole vectors, hide the retarget overlay). The cloak toggle
## is the odd one out: its neutral/default state is HIDDEN, not shown, so
## it's reset to pressed=true instead of being lumped in with the others.
func reset_display_toggles() -> void:
	for button in [right_hand_weapon_button, left_hand_weapon_button, left_shield_button, pole_vectors_button, overlay_button, play_button]:
		if button.button_pressed:
			button.button_pressed = false
	if not cloak_button.button_pressed:
		cloak_button.button_pressed = true

func _on_file_menu_pressed(id: int) -> void:
	match id:
		FILE_ID_NEW: new_confirm_dialog.popup_centered()
		FILE_ID_OPEN: _on_open_pressed()
		FILE_ID_SAVE: _on_save_pressed()
		FILE_ID_UNDO: undo_requested.emit()
		FILE_ID_FOCUS: focus_requested.emit()

func _on_utility_menu_pressed(id: int) -> void:
	match id:
		UTIL_ID_IMAGE: set_image_panel_open(true)
		UTIL_ID_VIDEO: video_pose_open_requested.emit()
		UTIL_ID_GLB: load_animation_dialog.popup_centered_ratio(0.6)
		UTIL_ID_BULK: ai_bulk_input_dialog.popup_centered_ratio(0.6)

## The reference-skeleton overlay follows the panel's lifecycle — main.gd
## binds to visibility_changed (see _bind_wizard_overlay), so just setting
## visible is enough. Apply pose must NOT touch the overlay: it stays up
## as a debug reference while iterating.
func set_image_panel_open(open: bool) -> void:
	image_pose_panel.visible = open

func get_anim_name() -> String:
	return _anim_name

func set_anim_name(value: String) -> void:
	_anim_name = value.strip_edges()
	header_name_label.text = _anim_name if _anim_name != "" else "untitled"

func set_duration(value: float) -> void:
	duration_edit.set_value_no_signal(value)
	timeline.set_length(value)

func _on_save_pressed() -> void:
	save_dialog.current_file = "%s.txt" % (_anim_name if _anim_name != "" else "animation")
	save_dialog.popup_centered_ratio(0.6)

## The animation name IS the chosen filename (without extension): one thing
## to type, and the header always reflects what will be exported.
func _on_save_file_selected(path: String) -> void:
	set_anim_name(path.get_file().get_basename())
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

var _bulk_input_dir: String = ""

func _on_bulk_input_selected(dir: String) -> void:
	_bulk_input_dir = dir
	ai_bulk_output_dialog.popup_centered_ratio(0.6)

func _on_bulk_output_selected(dir: String) -> void:
	ai_bulk_requested.emit(_bulk_input_dir, dir)

## ALL user notifications go through the single status bar at the bottom of
## the Edit sidebar — one consistent place the user learns to watch.
func set_bulk_progress(text: String) -> void:
	status_label.text = text

func set_bulk_running(running: bool) -> void:
	if running:
		image_pose_panel.visible = true
	utility_menu.disabled = running
	ai_load_image_button.disabled = running
	image_pose_panel.get_node("Body/BulkButton").disabled = running

func _on_ai_image_selected(path: String) -> void:
	image_pose_panel.get_node("Body/ImageRow/ImagePathLabel").text = path.get_file()
	set_image_panel_open(true)
	status_label.text = "Image loaded: %s" % path.get_file()
	ai_apply_pose_button.disabled = false
	ai_pose_image_selected.emit(path)

func set_ai_server_status(text: String) -> void:
	status_label.text = text

func set_ai_apply_enabled(enabled: bool) -> void:
	ai_apply_pose_button.disabled = not enabled

func is_ai_ground_enabled() -> bool:
	return ai_ground_check.button_pressed

## The four SOURCE TRANSFORM spinboxes of a wizard. The glb row is flat
## (RotYSpin/OffX/OffY/OffZ direct children), the AI panels nest RotYSpin
## under RotYRow and the offsets under OffsetRow.
func _source_xform_spins(container: Node, kind: String) -> Array:
	if kind == "glb":
		return [container.get_node("RotYSpin"), container.get_node("OffX"),
			container.get_node("OffY"), container.get_node("OffZ")]
	return [container.get_node("RotYRow/RotYSpin"), container.get_node("OffsetRow/OffX"),
		container.get_node("OffsetRow/OffY"), container.get_node("OffsetRow/OffZ")]

## User-authored source transform for the given wizard ("image"/"video"/
## "glb"): Y rotation plus world offset, applied to the reference skeleton
## preview and baked into Apply/Bake.
func get_source_xform(kind: String) -> Transform3D:
	var container: Node
	match kind:
		"image": container = image_pose_panel.get_node("Body")
		"video": container = video_pose_panel.get_node("Body")
		"glb": container = bone_config_panel.get_node("XformRow")
		_: return Transform3D.IDENTITY
	var spins := _source_xform_spins(container, kind)
	var basis := Basis(Vector3.UP, deg_to_rad(spins[0].value))
	var offset := Vector3(spins[1].value, spins[2].value, spins[3].value)
	return Transform3D(basis, offset)

func get_source_rot_y(kind: String) -> float:
	var xf := get_source_xform(kind)
	return xf.basis.get_euler().y

func reset_source_xform(kind: String) -> void:
	var container: Node
	match kind:
		"image": container = image_pose_panel.get_node("Body")
		"video": container = video_pose_panel.get_node("Body")
		"glb": container = bone_config_panel.get_node("XformRow")
		_: return
	for spin in _source_xform_spins(container, kind):
		spin.set_value_no_signal(0.0)

## Sets the unified overlay toggle's visual state without re-emitting.
func set_overlay_active(active: bool) -> void:
	overlay_button.set_pressed_no_signal(active)

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
