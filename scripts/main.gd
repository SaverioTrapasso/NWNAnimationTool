extends Node3D

const DragHandleScript = preload("res://scripts/drag_handle.gd")
const TranslationGizmoScript = preload("res://scripts/translation_gizmo.gd")
const AIPoseClientScript = preload("res://scripts/ai_pose_client.gd")
const AIPoseApplier = preload("res://scripts/ai_pose_applier.gd")
const VideoPoseClientScript = preload("res://scripts/video_pose_client.gd")

@onready var rig_controller: Node3D = $RigController
@onready var gizmo: Node3D = $RotationGizmo
@onready var side_panel: Control = $SidePanel
@onready var red_visualizer: Node3D = $RedVisualizer
@onready var green_visualizer: Node3D = $GreenVisualizer

var _current_model_path: String = "res://assets/nwn/a_ba.glb"

# Per-limb world-space IK targets, kept even while that limb isn't the
# active selection so arms/legs keep tracking their last pose as the body
# (e.g. the pelvis height) moves underneath them.
var _limb_targets: Dictionary = {} # component_id -> {"target": Vector3, "pole": Vector3}

var _active_ik_component: String = ""
var _target_handle: Node3D = null
var _pole_handle: Node3D = null
var _root_height_handle: Node3D = null
var _attachment_translate_handle: Node3D = null

## FK leaves with no mesh of their own (weapon/shield attachment dummies) --
## besides rotation, these also get a free-drag translate handle and an
## enabled position field in the transform panel, like the pelvis does.
const ATTACHMENT_COMPONENT_IDS := ["right_weapon", "left_weapon", "shield"]

## Nodes whose local basis should be forced to IDENTITY every frame,
## applied after the IK solver runs (used to zero-out hand rotation
## after an AI pose apply, since the IK solver would otherwise overwrite it).
var _zero_basis_overrides: Array[Node3D] = []

var _show_all_poles: bool = false
var _all_pole_handles: Dictionary = {} # component_id -> Node3D (drag handle)

# Original local transform of every Node3D under the rig, captured before
# any pose edits, so "Reset pose" can restore the rig exactly as imported.
var _rest_transforms: Dictionary = {} # Node3D -> Transform3D

# Timeline / keyframe state. Each keyframe is {"time": float, "transforms":
# {node_name: Transform3D}}, kept sorted ascending by time. NWN's own engine
# interpolates between these at runtime, so on export we just emit them in
# order; for the in-editor preview we interpolate the same way ourselves
# (independent per-node slerp/lerp) so what you see matches what NWN plays.
var _keyframes: Array = []
var _anim_length: float = 5.0

var _playing: bool = false
var _play_time: float = 0.0

# Undo: a short stack of full-pose snapshots, pushed right before each drag
# (gizmo/handle) starts, plus before Reset/Open. Ctrl+Z pops back one step.
const UNDO_MAX_SIZE := 20
var _undo_stack: Array = []
var _redo_stack: Array = []
var qol: Node = null
var mdl_bank: Node = null

# Clipboard for "Copy key" / "Paste key": lets you grab the pose at one point
# on the timeline and stamp it onto another keyframe, overwriting it.
var _copied_pose: Dictionary = {}

# Clipboard for "Copy sel." / "Paste sel.": the single currently-selected
# component's pose, independent of the timeline.
var _copied_component_pose: Dictionary = {}

var _nwn_skeleton := MeshInstance3D.new()
var _nwn_skeleton_mesh := ImmediateMesh.new()

func _ready() -> void:
	_nwn_skeleton.mesh = _nwn_skeleton_mesh
	var skeleton_material := StandardMaterial3D.new()
	skeleton_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	skeleton_material.no_depth_test = true
	skeleton_material.albedo_color = Color(1.0, .85, .15)
	_nwn_skeleton.material_override = skeleton_material
	_nwn_skeleton.visible = false
	add_child(_nwn_skeleton)
	get_window().title = "NWNAnimationTool"
	rig_controller.camera = $Camera3D
	rig_controller.rig_root = $Rig
	preload("res://scripts/game_staff_preview.gd").apply_hands($Rig,_current_model_path.ends_with("a_fa.glb"))
	rig_controller.setup()
	rig_controller.component_selected.connect(_on_component_selected)
	rig_controller.component_deselected.connect(_on_component_deselected)

	gizmo.camera = $Camera3D
	side_panel.rig_root = $Rig
	side_panel.rig_controller = rig_controller
	side_panel.reset_pressed.connect(_on_reset_pressed)
	side_panel.pole_vectors_toggled.connect(_on_pole_vectors_toggled)
	side_panel.save_file_requested.connect(_on_save_file_requested)
	side_panel.save_pose_requested.connect(func(path, name): _on_save_file_requested(path, name, true))
	side_panel.open_file_requested.connect(_on_open_file_requested)
	side_panel.save_to_timeline_requested.connect(_on_save_to_timeline_requested)
	side_panel.duration_changed.connect(_on_duration_changed)
	side_panel.timeline.time_changed.connect(_on_timeline_scrubbed)
	side_panel.timeline.key_move_started.connect(_push_undo_snapshot)
	side_panel.timeline.key_moved.connect(_move_single_key)
	side_panel.timeline.shift_drag_started.connect(_on_timeline_shift_drag_started)
	side_panel.timeline.shift_drag_moved.connect(_on_timeline_shift_drag_moved)
	side_panel.timeline.shift_drag_ended.connect(_on_timeline_shift_drag_ended)
	side_panel.play_toggled.connect(_on_play_toggled)
	side_panel.copy_key_requested.connect(_on_copy_key_requested)
	side_panel.paste_key_requested.connect(_on_paste_key_requested)
	side_panel.remove_key_requested.connect(_on_remove_key_requested)
	side_panel.set_duration(_anim_length)
	side_panel.transform_panel.position_changed.connect(_on_panel_position_changed)
	side_panel.transform_panel.rotation_changed.connect(_on_panel_rotation_changed)
	gizmo.rotation_requested.connect(_rotate_selection)
	side_panel.transform_panel.copy_selection_requested.connect(_on_copy_selection_requested)
	side_panel.transform_panel.paste_selection_requested.connect(_on_paste_selection_requested)
	side_panel.undo_requested.connect(_undo)
	side_panel.focus_requested.connect(_on_focus_pressed)
	side_panel.view_mode_requested.connect(func(mode: String): $Camera3D.set_view_mode(mode))
	gizmo.drag_started.connect(_push_undo_snapshot)

	side_panel.retarget_load_animation_requested.connect(_on_retarget_load_animation_requested)
	side_panel.retarget_bake_requested.connect(_on_retarget_bake_requested)
	side_panel.overlay_toggled.connect(_on_overlay_toggled)
	side_panel.bone_config_panel.cfg_import_requested.connect(_on_retarget_cfg_import_requested)
	side_panel.bone_config_panel.save_requested.connect(_on_retarget_save_config_requested)
	side_panel.bone_config_panel.save_as_chosen.connect(_on_retarget_save_as_chosen)
	side_panel.bone_config_panel.root_scale_changed.connect(_on_retarget_root_scale_changed)
	side_panel.bone_config_panel.flip_180_toggled.connect(_on_retarget_flip_180_toggled)
	side_panel.new_requested.connect(_on_new_requested)
	side_panel.gender_selected.connect(_on_gender_selected)

	_ai_client = AIPoseClientScript.new()
	_ai_client.name = "AIPoseClient"
	add_child(_ai_client)
	_ai_client.pose_received.connect(_on_ai_pose_received)
	_ai_client.pose_failed.connect(_on_ai_pose_failed)
	_ai_client.pose_notice.connect(side_panel.set_ai_server_status)
	side_panel.ai_pose_image_selected.connect(_on_ai_image_selected)
	side_panel.ai_pose_apply_requested.connect(_on_ai_apply_pose)
	side_panel.ai_ground_toggled.connect(func(_v: bool):
		if not _ai_pending_landmarks.is_empty():
			_show_ai_landmark_overlay(_ai_pending_landmarks))
	side_panel.source_xform_changed.connect(_on_source_xform_changed)
	side_panel.ai_bulk_requested.connect(_on_ai_bulk_requested)
	side_panel.timeline.delete_selected_requested.connect(_on_remove_key_requested)
	side_panel.pose_memory_save_requested.connect(_on_pose_memory_save)
	side_panel.pose_memory_load_requested.connect(_on_pose_memory_load)
	side_panel.pose_memory_open_requested.connect(_on_pose_memory_open)
	side_panel.video_pose_open_requested.connect(_on_video_pose_open)
	_setup_video_pose_panel()

	# UX rule shared by every motion-source wizard: opening the panel turns
	# its reference skeleton on, closing it turns it off. Bound to visibility
	# so it holds no matter how the panel gets opened or closed.
	_bind_wizard_overlay(side_panel.image_pose_panel, "ai")
	_bind_wizard_overlay(_video_panel, "ai")
	_bind_wizard_overlay(side_panel.bone_config_panel, "retarget")

	red_visualizer.camera = $Camera3D
	side_panel.bone_config_panel.set_bone_map(RetargetConfig.NWN_NODES, {}) # rows visible immediately, dropdowns filled in once a config/animation is loaded

	side_panel.apply_initial_cloak_state()
	side_panel.set_active_gender(_current_model_path)
	_apply_component_materials($Rig)
	_capture_rest_transforms($Rig)
	_init_default_limb_targets()
	_apply_nwn_idle()
	qol = preload("res://scripts/workshop.gd").new()
	qol.name = "Workshop"
	add_child(qol)
	mdl_bank = preload("res://scripts/mdl_bank.gd").new()
	mdl_bank.name = "MdlBank"
	add_child(mdl_bank)
	mdl_bank.dialog.canceled.connect(func(): _pose_memory_pending_slot = -1)
	mdl_bank.dialog.confirmed.connect(func(): _pose_memory_pending_slot = -1)
	var all_button := Button.new()
	all_button.text = "All"
	all_button.focus_mode = Control.FOCUS_NONE
	all_button.tooltip_text = "Select all body parts (Ctrl+A)"
	all_button.pressed.connect(rig_controller.select_all_body)
	side_panel.viewport_toolbar.add_child(all_button)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if _nudge_selection(event):
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_A and event.is_command_or_control_pressed() and get_viewport().gui_get_focus_owner() == null:
			rig_controller.select_all_body()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_Z and event.is_command_or_control_pressed():
			if event.shift_pressed: _redo()
			else: _undo()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_Y and event.is_command_or_control_pressed():
			_redo()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_F:
			_on_focus_pressed()
			get_viewport().set_input_as_handled()

## Recenters the orbit camera on whatever's currently selected (its IK target
## for limbs, its own position for FK parts), or the torso if nothing is
## selected — handy after losing track of the model while orbiting/panning.
func _on_focus_pressed() -> void:
	var camera: Camera3D = $Camera3D
	var component_id: String = rig_controller.selected_component
	var pos: Vector3

	if component_id == "":
		var torso: Node3D = rig_controller.find_node("torso_g")
		pos = torso.global_position if torso != null else Vector3.ZERO
	else:
		var is_ik := false
		for comp in RigComponents.definitions():
			if comp.id == component_id:
				is_ik = comp.is_ik
				break
		if is_ik:
			var chain: Array[Node3D] = rig_controller.get_chain_nodes(component_id)
			pos = chain[2].global_position if chain.size() == 3 else Vector3.ZERO
		else:
			var node: Node3D = rig_controller.get_component_root_node(component_id)
			pos = node.global_position if node != null else Vector3.ZERO

	camera.focus_on(pos)

func _document_state() -> Dictionary:
	return {"pose": MdlExporter.capture_pose($Rig), "keys": _keyframes.duplicate(true),
		"length": _anim_length, "time": side_panel.timeline.current_time,
		"name": side_panel.get_anim_name(), "model": _current_model_path,
		"bank_clip": mdl_bank.active_clip if mdl_bank != null else "",
		"bank_session": mdl_bank.session if mdl_bank != null else ""}

func _restore_document(state: Dictionary) -> void:
	if mdl_bank != null and (state.get("bank_clip", "") != mdl_bank.active_clip or state.get("bank_session", "") != mdl_bank.session):
		mdl_bank.active_clip = ""
	_on_play_toggled(false)
	if state.get("model", _current_model_path) != _current_model_path:
		_on_gender_selected(state.model)
	_keyframes = state["keys"].duplicate(true)
	_anim_length = state.length
	side_panel.set_anim_name(state.name)
	side_panel.set_duration(_anim_length)
	_refresh_timeline_markers()
	side_panel.timeline.set_current_time(state.time)
	_apply_transforms(state.pose)
	if qol != null: qol.release_constraints()

func _push_undo_snapshot() -> void:
	_undo_stack.append(_document_state())
	_redo_stack.clear()
	if qol != null: qol.dirty = true
	if _undo_stack.size() > 80: _undo_stack.pop_front()

func _undo() -> void:
	if _undo_stack.is_empty(): return
	_redo_stack.append(_document_state())
	_restore_document(_undo_stack.pop_back())
	if qol != null: qol.dirty = true
	side_panel.set_status("Undo (Ctrl+Z).")

func _redo() -> void:
	if _redo_stack.is_empty(): return
	_undo_stack.append(_document_state())
	_restore_document(_redo_stack.pop_back())
	if qol != null: qol.dirty = true
	side_panel.set_status("Redo (Ctrl+Y / Ctrl+Shift+Z).")

func _capture_rest_transforms(node: Node) -> void:
	if node is Node3D:
		_rest_transforms[node] = node.transform
	for child in node.get_children():
		_capture_rest_transforms(child)

func _set_t_pose() -> void:
	_push_undo_snapshot()
	_playing = false
	side_panel.set_playing(false)
	if qol != null: qol.release_constraints()
	for node in _rest_transforms:
		if is_instance_valid(node): node.transform = _rest_transforms[node]
	# Straighten each arm out from its shoulder, retaining native bone lengths.
	for id in ["left_arm", "right_arm"]:
		var chain: Array = rig_controller.get_chain_nodes(id)
		var direction := Vector3.LEFT if id == "left_arm" else Vector3.RIGHT
		for i in range(2):
			var current: Vector3 = (chain[i + 1].global_position - chain[i].global_position).normalized()
			chain[i].global_basis = Basis(Quaternion(current, direction)) * chain[i].global_basis
	_resync_limb_targets_from_current_pose()
	if rig_controller.selected_component != "":
		_on_component_selected(rig_controller.selected_component)
	_refresh_all_pole_handles()
	side_panel.set_status("T-pose applied. Set a key to add it to the animation; Ctrl+Z to undo.")

func _on_reset_pressed() -> void:
	_push_undo_snapshot()
	for node in _rest_transforms.keys():
		if is_instance_valid(node):
			node.transform = _rest_transforms[node]
	_init_default_limb_targets()
	_apply_nwn_idle()
	var current_selection: String = rig_controller.selected_component
	if current_selection != "":
		_on_component_selected(current_selection)
	_refresh_all_pole_handles()

## Swaps the loaded NWN dummy for the other gender's model. Both share the
## same node names/hierarchy (rootdummy, pelvis_g, torso_g, ...), so every
## downstream system that reads $Rig by node name -- timeline keyframes,
## MdlExporter/MdlImporter, the retarget overlay -- keeps working unchanged
## once the new instance is named "Rig" and dropped in at the same spot.
func _on_gender_selected(model_path: String) -> void:
	if model_path == _current_model_path:
		return
	var new_scene: Resource = load(model_path)
	if new_scene == null or not (new_scene is PackedScene):
		side_panel.set_status("Could not load model: %s" % model_path)
		return
	var new_rig: Node3D = new_scene.instantiate()
	new_rig.name = "Rig"

	# Drop anything that points at the OLD $Rig's nodes before freeing it --
	# including weapon previews, which are parented under the old rig's
	# rhand/lhand dummies and would otherwise be left as dangling refs.
	side_panel.reset_display_toggles()
	rig_controller.deselect()
	_clear_handles()
	gizmo.detach()
	_all_pole_handles.clear()
	_limb_targets.clear()
	_rest_transforms.clear()

	var old_rig: Node3D = $Rig
	var idx: int = old_rig.get_index()
	var parent: Node = old_rig.get_parent()
	parent.remove_child(old_rig)
	old_rig.queue_free()
	parent.add_child(new_rig)
	parent.move_child(new_rig, idx)

	preload("res://scripts/game_staff_preview.gd").apply_hands(new_rig,model_path.ends_with("a_fa.glb"))
	rig_controller.rebuild(new_rig)
	side_panel.rig_root = new_rig

	_apply_component_materials(new_rig)
	_capture_rest_transforms(new_rig)
	_init_default_limb_targets()
	side_panel.apply_initial_cloak_state()
	_refresh_all_pole_handles()

	# Existing keyframes/timeline pose are keyed by NODE NAME, not by Node3D
	# reference, so they apply cleanly to the new rig as-is -- just need to
	# actually re-apply the current frame against the new nodes.
	if not _keyframes.is_empty():
		_apply_pose_at_time(side_panel.timeline.current_time)
	else:
		_apply_nwn_idle()

	_current_model_path = model_path
	side_panel.set_active_gender(model_path)
	side_panel.set_status("Model switched to %s" % model_path.get_file())

## New resets the document and preview tools. The animation is recoverable with Undo.
func _on_new_requested() -> void:
	_push_undo_snapshot()
	if mdl_bank != null: mdl_bank.active_clip = ""
	if qol != null: qol.release_constraints()
	for node in _rest_transforms.keys():
		if is_instance_valid(node):
			node.transform = _rest_transforms[node]
	_init_default_limb_targets()
	rig_controller.deselect()
	_clear_handles()
	gizmo.detach()
	_show_all_poles = false
	_refresh_all_pole_handles()

	_keyframes.clear()
	_anim_length = 5.0
	_playing = false
	_play_time = 0.0
	side_panel.set_anim_name("")
	side_panel.set_duration(_anim_length)
	_refresh_timeline_markers()
	side_panel.timeline.set_current_time(0.0)

	_copied_pose = {}
	_copied_component_pose = {}

	_retarget_model_path = ""
	if _retarget_anim_scene != null:
		_retarget_anim_scene.queue_free()
		_retarget_anim_scene = null
	_show_retarget_overlay = false
	_retarget_lock = {}
	_retarget_flip_180 = false
	red_visualizer.visible = false
	if side_panel.bone_config_panel.visible:
		side_panel.bone_config_panel.toggle_visible()
	if not _retarget_config_path.is_empty():
		_on_retarget_cfg_import_requested(_retarget_config_path) # reloads from disk, discarding unsaved edits

	for kind in ["image", "video", "glb"]:
		side_panel.reset_source_xform(kind)
	green_visualizer.transform = Transform3D.IDENTITY

	side_panel.reset_display_toggles()
	_apply_nwn_idle()
	side_panel.set_status("New project started.")

func _apply_nwn_idle() -> void:
	var path: String = WorkshopSettings.path_value("idle")
	if path.is_empty() or not FileAccess.file_exists(path): return
	var source := FileAccess.get_file_as_string(path)
	var idle: Variant = MdlImporter.parse(source, $Rig)
	if idle != null:
		_apply_transforms(idle.keyframes[0].transforms)
		if _keyframes.is_empty(): side_panel.set_anim_name("pause1")

func _on_pole_vectors_toggled(show_all: bool) -> void:
	_show_all_poles = show_all
	_refresh_all_pole_handles()

## Shows a draggable pole-vector handle for every IK limb that ISN'T the
## currently active selection (the active one already has its own pole
## handle from _setup_ik_handles). Useful to review/tweak all limb bends
## at once without selecting each limb individually.
func _refresh_all_pole_handles() -> void:
	for component_id in _all_pole_handles.keys():
		_retire_handle(_all_pole_handles[component_id])
	_all_pole_handles.clear()

	if not _show_all_poles:
		return
	for comp in RigComponents.definitions():
		if not comp.is_ik or comp.id == _active_ik_component:
			continue
		if not _limb_targets.has(comp.id):
			continue
		var handle := DragHandleScript.new()
		handle.color = Color(0.2, 0.9, 1.0, 0.6)
		add_child(handle)
		handle.camera = $Camera3D
		handle.global_position = _limb_targets[comp.id]["pole"]
		handle.moved.connect(_on_all_pole_moved.bind(comp.id))
		handle.drag_started.connect(_push_undo_snapshot)
		_all_pole_handles[comp.id] = handle

func _on_all_pole_moved(pos: Vector3, component_id: String) -> void:
	if _limb_targets.has(component_id):
		_limb_targets[component_id]["pole"] = pos

## Anchors every IK limb (hands/feet) to its current world position right
## away, even before the user selects it. Without this, an untouched limb
## has no IK target yet and would move rigidly with the pelvis/torso instead
## of staying planted (e.g. feet sliding when the pelvis height changes).
func _init_default_limb_targets() -> void:
	_zero_basis_overrides.clear()
	var root_dummy: Node3D = rig_controller.find_node("rootdummy")
	var body_forward: Vector3 = root_dummy.global_basis * Vector3.FORWARD if root_dummy != null else Vector3.FORWARD

	for comp in RigComponents.definitions():
		if not comp.is_ik:
			continue
		var chain: Array[Node3D] = rig_controller.get_chain_nodes(comp.id)
		if chain.size() != 3:
			continue
		var root_node: Node3D = chain[0]
		var mid_node: Node3D = chain[1]
		var end_node: Node3D = chain[2]

		# Legs bend the knee forward, arms bend the elbow backward — using
		# the body's front/back axis (instead of left/right) keeps both
		# limbs' poles in an intuitive, non-mirrored spot for newcomers.
		var is_leg: bool = comp.id.ends_with("_leg")
		var pole_axis: Vector3 = body_forward if is_leg else -body_forward
		var limb_dir: Vector3 = (mid_node.global_position - root_node.global_position).normalized()
		var outward: Vector3 = pole_axis - limb_dir * pole_axis.dot(limb_dir) # keep it perpendicular to the limb
		if outward.length() < 0.0001:
			outward = Vector3.UP
		outward = outward.normalized()

		_limb_targets[comp.id] = {
			"target": end_node.global_position,
			"pole": mid_node.global_position + outward * 0.3,
			"end_basis": end_node.global_basis,
		}

## Recomputes every IK limb's target/pole from the rig's CURRENT pose, so the
## live solver (which runs every frame from _limb_targets) reproduces exactly
## the pose that was just applied directly (e.g. from a timeline keyframe)
## instead of fighting it on the next frame. Because target/pole come from
## the limb's own current geometry, solve_two_bone is guaranteed to land
## back on the same configuration.
func _resync_limb_targets_from_current_pose() -> void:
	for comp in RigComponents.definitions():
		if not comp.is_ik:
			continue
		var chain: Array[Node3D] = rig_controller.get_chain_nodes(comp.id)
		if chain.size() != 3:
			continue
		_limb_targets[comp.id] = {
			"target": chain[2].global_position,
			"pole": chain[1].global_position,
			"end_basis": chain[2].global_basis,
		}

const COLOR_NEUTRAL := Color(0.85, 0.85, 0.83)
const COLOR_IK := Color(0.95, 0.82, 0.15) # yellow: draggable IK parts (hands/feet)
const COLOR_FK := Color(0.25, 0.65, 0.95) # cyan/azzurro: rotatable FK parts (head/torso/pelvis)

## Tints FK parts (head/torso/pelvis) cyan, and only the hand/foot tip of
## each IK limb yellow (not the whole bicep/forearm or thigh/shin chain), so
## the user can see at a glance what's directly draggable; everything else
## (decorative meshes, upper limb segments) stays a neutral clay color.
func _apply_component_materials(node: Node) -> void:
	var node_to_component := RigComponents.node_to_component_map()
	var ik_tip_names := {}
	var fk_component_ids := {}
	for comp in RigComponents.definitions():
		if comp.is_ik:
			ik_tip_names[comp.chain[comp.chain.size() - 1]] = true
		else:
			fk_component_ids[comp.id] = true
	_apply_component_materials_recursive(node, node_to_component, ik_tip_names, fk_component_ids)

func _apply_component_materials_recursive(node: Node, node_to_component: Dictionary, ik_tip_names: Dictionary, fk_component_ids: Dictionary) -> void:
	if node is MeshInstance3D:
		var color := COLOR_NEUTRAL
		if ik_tip_names.has(node.name):
			color = COLOR_IK
		elif node_to_component.has(node.name) and node_to_component[node.name] in ["head", "torso", "pelvis"]:
			color = COLOR_FK
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.roughness = 0.85
		mat.metallic = 0.0
		node.material_override = mat
	for child in node.get_children():
		_apply_component_materials_recursive(child, node_to_component, ik_tip_names, fk_component_ids)

func _process(delta: float) -> void:
	if _playing and not _keyframes.is_empty():
		_play_time += delta
		if _anim_length > 0.0001:
			_play_time = fmod(_play_time, _anim_length)
		side_panel.timeline.set_current_time(_play_time)
		_apply_pose_at_time(_play_time)
		_sync_retarget_overlay(_play_time)
		_sync_video_pose_overlay(_play_time)

	for component_id in _limb_targets.keys():
		if rig_controller.has_fk_selection_in(rig_controller.get_component_chain(component_id)): continue
		var chain: Array[Node3D] = rig_controller.get_chain_nodes(component_id)
		if chain.size() != 3:
			continue
		var t: Dictionary = _limb_targets[component_id]
		if component_id == _active_ik_component:
			# Being edited right now: capture whatever the rotation gizmo just
			# set, so it becomes the new pinned orientation once deselected.
			t["end_basis"] = chain[2].global_basis
		else:
			# Not selected: re-pin the hand/foot to its remembered world
			# orientation. Without this it would silently inherit any
			# rotation from an ancestor (e.g. rotating the pelvis) instead of
			# staying put, since global_basis = parent_global_basis * local.
			chain[2].basis = chain[1].global_basis.inverse() * t["end_basis"]
		IKSolver.solve_two_bone(chain[0], chain[1], chain[2], t["target"], t["pole"])
	for node in _zero_basis_overrides:
		if is_instance_valid(node):
			node.basis = Basis.IDENTITY
	if _attachment_translate_handle != null and gizmo.target != null:
		_attachment_translate_handle.global_position = gizmo.target.global_position
	_refresh_transform_panel()
	if _nwn_skeleton.visible: _update_nwn_skeleton()

func _on_play_toggled(playing: bool) -> void:
	if playing and _keyframes.is_empty():
		side_panel.set_status("Add at least one keyframe to the timeline first.")
		side_panel.set_playing(false)
		return
	_playing = playing
	if playing:
		_play_time = side_panel.timeline.current_time

## Scrubbing the timeline by hand while it's playing pauses playback, so the
## user's drag wins instead of being immediately overridden next frame.
func _on_timeline_scrubbed(t: float) -> void:
	if _playing:
		_playing = false
		side_panel.set_playing(false)
	_apply_pose_at_time(t)
	_sync_retarget_overlay(t)
	_sync_video_pose_overlay(t)

func _sync_video_pose_overlay(t: float) -> void:
	if not green_visualizer.visible or _video_extracted_frames.is_empty():
		return
	# Find the closest extracted frame to time t
	var best_idx := 0
	var best_dist := INF
	for i in _video_extracted_frames.size():
		var d: float = abs(_video_extracted_frames[i]["time"] - t)
		if d < best_dist:
			best_dist = d
			best_idx = i
	_show_ai_landmark_overlay(_video_extracted_frames[best_idx]["world_landmarks"])

func _on_component_selected(component_id: String) -> void:
	_resync_limb_targets_from_current_pose()
	_clear_handles()
	var is_ik := false
	for comp in RigComponents.definitions():
		if comp.id == component_id:
			is_ik = comp.is_ik
			break
	if rig_controller.selected_components.size() > 1:
		gizmo.attach_to(rig_controller.selection_roots()[0])
		_setup_attachment_translate_handle(component_id)
	elif is_ik:
		_setup_ik_handles(component_id)
		var chain: Array[Node3D] = rig_controller.get_chain_nodes(component_id)
		if chain.size() == 3:
			gizmo.attach_to(chain[2]) # let the user orient the hand/foot independently of the IK solve
		else:
			gizmo.detach()
	else:
		gizmo.attach_to(rig_controller.get_component_root_node(component_id))
		if component_id == "pelvis":
			_setup_root_height_handle()
		else:
			_setup_attachment_translate_handle(component_id)
	_refresh_all_pole_handles()

	side_panel.transform_panel.visible = true
	side_panel.transform_panel.set_label("All — whole character" if rig_controller.all_body_selected() else ", ".join(rig_controller.selected_components))
	side_panel.transform_panel.set_position_enabled(is_ik or _can_translate_selection())

func _on_component_deselected() -> void:
	_resync_limb_targets_from_current_pose()
	gizmo.detach()
	_clear_handles()
	_refresh_all_pole_handles()
	side_panel.transform_panel.visible = false

func _setup_ik_handles(component_id: String) -> void:
	_active_ik_component = component_id
	if not _limb_targets.has(component_id):
		return
	var t: Dictionary = _limb_targets[component_id]

	_target_handle = TranslationGizmoScript.new()
	_target_handle.color = Color(1.0, 0.85, 0.1)
	add_child(_target_handle)
	_target_handle.camera = $Camera3D
	_target_handle.global_position = t["target"]
	_target_handle.moved.connect(_on_target_moved)
	_target_handle.drag_started.connect(_push_undo_snapshot)

	_pole_handle = DragHandleScript.new()
	_pole_handle.color = Color(0.2, 0.9, 1.0)
	add_child(_pole_handle)
	_pole_handle.camera = $Camera3D
	_pole_handle.global_position = t["pole"]
	_pole_handle.moved.connect(_on_pole_moved)
	_pole_handle.drag_started.connect(_push_undo_snapshot)

func _on_target_moved(pos: Vector3) -> void:
	if _active_ik_component != "":
		_limb_targets[_active_ik_component]["target"] = pos

func _on_pole_moved(pos: Vector3) -> void:
	if _active_ik_component != "":
		_limb_targets[_active_ik_component]["pole"] = pos

func _setup_root_height_handle() -> void:
	var root_dummy: Node3D = rig_controller.find_node("rootdummy")
	if root_dummy == null:
		return
	_root_height_handle = TranslationGizmoScript.new()
	_root_height_handle.color = Color(0.6, 1.0, 0.4)
	add_child(_root_height_handle)
	_root_height_handle.camera = $Camera3D
	_root_height_handle.global_position = root_dummy.global_position
	_root_height_handle.moved.connect(_on_root_height_moved)
	_root_height_handle.drag_started.connect(_push_undo_snapshot)

func _on_root_height_moved(pos: Vector3) -> void:
	var root_dummy: Node3D = rig_controller.find_node("rootdummy")
	if root_dummy != null:
		root_dummy.global_position = pos

## right_weapon/left_weapon/shield are single-node FK leaves (the rhand/
## lhand/lforearm attachment dummies) -- unlike head/torso/pelvis they're
## useful to reposition too, e.g. nudging a weapon's grip point or a
## shield's offset without disturbing the limb that's holding it.
func _setup_attachment_translate_handle(component_id: String) -> void:
	if not _can_translate_selection(): return
	var node: Node3D = rig_controller.get_component_root_node(component_id)
	if node == null:
		return
	_attachment_translate_handle = TranslationGizmoScript.new()
	_attachment_translate_handle.color = Color(1.0, 0.6, 0.9)
	add_child(_attachment_translate_handle)
	_attachment_translate_handle.camera = $Camera3D
	_attachment_translate_handle.global_position = _translation_anchor()
	_attachment_translate_handle.moved.connect(_on_attachment_translate_moved.bind(component_id))
	_attachment_translate_handle.drag_started.connect(_push_undo_snapshot)
	_attachment_translate_handle.drag_started.connect(_begin_selection_translation)

func _on_attachment_translate_moved(pos: Vector3, _component_id: String) -> void:
	_translate_selection(pos)

func _translation_chain(node: Node3D) -> Array[Node3D]:
	for id in ["right_arm", "left_arm", "right_leg", "left_leg"]:
		if str(node.name) in rig_controller.get_component_chain(id):
			return rig_controller.get_chain_nodes(id)
	return []

func _joint_tip(node: Node3D) -> Node3D:
	var chain := _translation_chain(node)
	if chain.size() == 3: return chain[2]
	return rig_controller.find_node("rootdummy") if node.name == "pelvis_g" else node

func _translation_anchor() -> Vector3:
	return gizmo.target.global_position

func _can_translate_selection() -> bool:
	for node in rig_controller.selection_roots():
		if node.name in ["head_g", "torso_g"]: return false
	return not rig_controller.selected_components.is_empty()

var _selection_translation_pose: Dictionary = {}
var _selection_translation_poles: Dictionary = {}
var _selection_translation_origin := Vector3.ZERO

func _begin_selection_translation() -> void:
	_selection_translation_origin = _translation_anchor()
	_selection_translation_pose = MdlExporter.capture_pose($Rig)
	_selection_translation_poles = _limb_targets.duplicate(true)

func _translate_selection(pos: Vector3) -> void:
	if not _can_translate_selection(): return
	if _selection_translation_pose.is_empty(): _begin_selection_translation()
	# Every drag event starts from the same pose; do not accumulate cursor deltas.
	for name in _selection_translation_pose:
		rig_controller.find_node(name).transform = _selection_translation_pose[name]
	var offset := pos - _selection_translation_origin
	var nodes: Array[Node3D] = rig_controller.selection_roots()
	var targets: Array[Vector3] = []
	for node in nodes: targets.append(_joint_tip(node).global_position + offset)
	for i in nodes.size():
		var node := nodes[i]
		var tip := _joint_tip(node)
		var target := targets[i]
		if node.name in ["pelvis_g", "rootdummy"]:
			tip.global_position = target
		elif not _translation_chain(node).is_empty():
			var chain := _translation_chain(node)
			var limb_id := ""
			for id in ["right_arm", "left_arm", "right_leg", "left_leg"]:
				if str(node.name) in rig_controller.get_component_chain(id): limb_id = id
			IKSolver.solve_two_bone(chain[0], chain[1], chain[2], target, _selection_translation_poles[limb_id]["pole"])
		elif node.name in ["rhand", "lhand", "lforearm"]:
			node.global_position = target
	_resync_limb_targets_from_current_pose()
	if _attachment_translate_handle != null: _attachment_translate_handle.global_position = _translation_anchor()


## queue_free() only removes the node at the end of this frame — until then
## it's still in the tree and would still react to the very same click that's
## replacing it (e.g. the click that selects a new component), nudging
## whatever's newly selected with a stray drag from the old, doomed handle.
## Disabling its input processing immediately closes that window.
func _retire_handle(handle: Node) -> void:
	if handle == null:
		return
	if handle.has_method("set_process_unhandled_input"):
		handle.set_process_unhandled_input(false)
	handle.queue_free()

func _clear_handles() -> void:
	_selection_translation_pose.clear()
	_active_ik_component = ""
	if _target_handle != null:
		_retire_handle(_target_handle)
		_target_handle = null
	if _pole_handle != null:
		_retire_handle(_pole_handle)
		_pole_handle = null
	if _root_height_handle != null:
		_retire_handle(_root_height_handle)
		_root_height_handle = null
	if _attachment_translate_handle != null:
		_retire_handle(_attachment_translate_handle)
		_attachment_translate_handle = null

# ---------------------------------------------------------------------------
# Timeline / keyframes
# ---------------------------------------------------------------------------

func _on_duration_changed(value: float) -> void:
	_push_undo_snapshot()
	var ratio: float = value / max(_anim_length, 0.001)
	for key in _keyframes: key["time"] *= ratio
	_play_time *= ratio
	_anim_length = value
	_refresh_timeline_markers()
	side_panel.set_duration(value)

func _on_save_to_timeline_requested() -> void:
	_push_undo_snapshot()
	var transforms: Dictionary = MdlExporter.capture_pose($Rig)
	var t: float = side_panel.timeline.current_time
	_upsert_keyframe(t, transforms)
	side_panel.set_status("Keyframe saved at %.2fs" % t)

func _upsert_keyframe(t: float, transforms: Dictionary) -> void:
	for kf in _keyframes:
		if abs(kf["time"] - t) < 0.001:
			kf["transforms"] = transforms
			_refresh_timeline_markers()
			return
	_keyframes.append({"time": t, "transforms": transforms})
	_keyframes.sort_custom(func(a, b): return a["time"] < b["time"])
	_refresh_timeline_markers()

## Deletes the keyframe at the current timeline position, if any. Without
## this there was no way to get rid of a bad keyframe short of starting the
## whole animation over.
func _on_remove_key_requested() -> void:
	var selected: Array = side_panel.timeline.selected_times.duplicate()
	if not selected.is_empty():
		_push_undo_snapshot()
		_on_play_toggled(false)
		_keyframes = _keyframes.filter(func(key): return not selected.has(key.time))
		side_panel.timeline.clear_selection()
		_refresh_timeline_markers()
		_apply_pose_at_time(side_panel.timeline.current_time)
		side_panel.set_status("Removed %d selected keyframes. Undo restores them." % selected.size())
		return
	var t: float = side_panel.timeline.current_time
	for i in range(_keyframes.size()):
		if abs(_keyframes[i]["time"] - t) < 0.005:
			_push_undo_snapshot()
			_keyframes.remove_at(i)
			_refresh_timeline_markers()
			side_panel.set_status("Keyframe at %.2fs removed." % t)
			return
	side_panel.set_status("No keyframe exactly at %.2fs to remove." % t)

func _refresh_timeline_markers() -> void:
	var times: Array = []
	for kf in _keyframes:
		times.append(kf["time"])
	side_panel.timeline.set_keyframe_times(times)
	side_panel.timeline.key_labels.clear()
	for key in _keyframes: side_panel.timeline.key_labels[key.time] = key.get("label", "")

# ---------------------------------------------------------------------------
# Shift+drag a keyframe: rigidly slides it and every keyframe to its right
# by the same amount (e.g. to squeeze out an unwanted opening key pose by
# dragging the second keyframe back toward 0). Keyframes to the LEFT of the
# one grabbed never move.
# ---------------------------------------------------------------------------

# {"time": float, "transforms": Dictionary} per entry, captured once when the
# drag starts so every motion event recomputes from the same baseline
# instead of compounding rounding error onto itself frame after frame.
var _shift_drag_snapshot: Array = []

func _on_timeline_shift_drag_started(_anchor_time: float) -> void:
	_push_undo_snapshot()
	_shift_drag_snapshot = []
	for kf in _keyframes:
		_shift_drag_snapshot.append(kf.duplicate(true))

func _on_timeline_shift_drag_moved(anchor_time: float, delta_time: float) -> void:
	if _shift_drag_snapshot.is_empty():
		return

	var anchor_idx := 0
	var best_dist := INF
	for i in range(_shift_drag_snapshot.size()):
		var dist: float = abs(_shift_drag_snapshot[i]["time"] - anchor_time)
		if dist < best_dist:
			best_dist = dist
			anchor_idx = i

	# Clamp so the shifted group can't cross the keyframe just before it
	# (or go below 0, if it's the first keyframe) and can't push the last
	# keyframe past the end of the animation -- a single delta clamped once
	# keeps the whole group's relative spacing exactly intact.
	const MIN_GAP := 0.01
	var anchor_time_snap: float = _shift_drag_snapshot[anchor_idx]["time"]
	var prev_time: float = _shift_drag_snapshot[anchor_idx - 1]["time"] if anchor_idx > 0 else 0.0
	var last_time: float = _shift_drag_snapshot[_shift_drag_snapshot.size() - 1]["time"]
	var min_delta: float = (prev_time - anchor_time_snap + MIN_GAP) if anchor_idx > 0 else (0.0 - anchor_time_snap)
	var max_delta: float = _anim_length - last_time
	var clamped_delta: float = clamp(delta_time, min_delta, max(max_delta, min_delta))

	var new_keyframes: Array = []
	for i in range(_shift_drag_snapshot.size()):
		var kf: Dictionary = _shift_drag_snapshot[i]
		var new_time: float = kf["time"] + clamped_delta if i >= anchor_idx else kf["time"]
		var moved_key: Dictionary = kf.duplicate(true)
		moved_key["time"] = new_time
		new_keyframes.append(moved_key)
	_keyframes = new_keyframes

	_refresh_timeline_markers()
	var new_anchor_time: float = anchor_time_snap + clamped_delta
	side_panel.timeline.set_current_time(new_anchor_time)
	_apply_pose_at_time(new_anchor_time)

func _on_timeline_shift_drag_ended() -> void:
	if not _shift_drag_snapshot.is_empty():
		side_panel.set_status("Keyframes shifted.")
	_shift_drag_snapshot = []

## Copies the pose currently shown at the timeline's playhead (whether
## that's an exact keyframe or an interpolated in-between moment) so it can
## be stamped onto another point on the timeline with "Paste key".
func _on_copy_key_requested() -> void:
	_copied_pose = MdlExporter.capture_pose($Rig)
	side_panel.set_status("Pose copied (t=%.2fs)." % side_panel.timeline.current_time)

## Overwrites (or creates) the keyframe at the current playhead time with
## the last copied pose, and applies it immediately so you see the result.
func _on_paste_key_requested() -> void:
	if _copied_pose.is_empty():
		side_panel.set_status("Nothing copied yet — use \"Copy key\" first.")
		return
	_push_undo_snapshot()
	var t: float = side_panel.timeline.current_time
	_upsert_keyframe(t, _copied_pose.duplicate())
	_apply_pose_at_time(t)
	side_panel.set_status("Pose pasted at %.2fs." % t)

func _is_ik_component(component_id: String) -> bool:
	for comp in RigComponents.definitions():
		if comp.id == component_id:
			return comp.is_ik
	return false

## Copies only the currently selected component's pose (its IK target/pole/
## hand-or-foot orientation, or its FK rotation — plus the body position for
## the pelvis), as opposed to "Copy key" which grabs the entire rig.
func _on_copy_selection_requested() -> void:
	var component_id: String = rig_controller.selected_component
	if component_id == "":
		side_panel.set_status("Select something first.")
		return

	if _is_ik_component(component_id):
		var t: Dictionary = _limb_targets[component_id]
		_copied_component_pose = {
			"type": "ik",
			"target": t["target"],
			"pole": t["pole"],
			"end_basis": t["end_basis"],
		}
	else:
		var node: Node3D = rig_controller.get_component_root_node(component_id)
		_copied_component_pose = {"type": "fk", "basis": node.basis}
		if component_id == "pelvis":
			var root_dummy: Node3D = rig_controller.find_node("rootdummy")
			if root_dummy != null:
				_copied_component_pose["root_position"] = root_dummy.global_position

	side_panel.set_status("Copied %s." % component_id)

## Applies the copied component pose onto whatever's currently selected, as
## long as it's the same kind (IK limb onto IK limb, FK part onto FK part) —
## e.g. copy the right hand's grip and paste it onto the left hand.
func _on_paste_selection_requested() -> void:
	if _copied_component_pose.is_empty():
		side_panel.set_status("Nothing copied yet — use \"Copy sel.\" first.")
		return
	var component_id: String = rig_controller.selected_component
	if component_id == "":
		side_panel.set_status("Select something to paste onto first.")
		return

	var is_ik := _is_ik_component(component_id)
	var copy_type: String = _copied_component_pose["type"]
	if (copy_type == "ik") != is_ik:
		side_panel.set_status("Can't paste an IK limb's pose onto an FK part (or vice versa).")
		return

	_push_undo_snapshot()
	if is_ik:
		_limb_targets[component_id]["target"] = _copied_component_pose["target"]
		_limb_targets[component_id]["pole"] = _copied_component_pose["pole"]
		_limb_targets[component_id]["end_basis"] = _copied_component_pose["end_basis"]
	else:
		var node: Node3D = rig_controller.get_component_root_node(component_id)
		if node != null:
			node.basis = _copied_component_pose["basis"]
		if component_id == "pelvis" and _copied_component_pose.has("root_position"):
			var root_dummy: Node3D = rig_controller.find_node("rootdummy")
			if root_dummy != null:
				root_dummy.global_position = _copied_component_pose["root_position"]
	_on_component_selected(component_id) # refresh handles/gizmo to the new pose
	side_panel.set_status("Pasted onto %s." % component_id)

## Previews the rig at time t by interpolating between the two keyframes
## bracketing it (independent per-node lerp/slerp — the same way NWN's own
## engine interpolates orientationkey/positionkey tracks at runtime, so the
## preview matches what will actually play in-game).
func _apply_pose_at_time(t: float) -> void:
	if _keyframes.is_empty():
		return
	var first: Dictionary = _keyframes[0]
	var last: Dictionary = _keyframes[_keyframes.size() - 1]
	var a: Dictionary = first
	var b: Dictionary = first
	if t <= first["time"]:
		a = first
		b = first
	elif t >= last["time"]:
		a = last
		b = last
	else:
		for i in range(_keyframes.size() - 1):
			if _keyframes[i]["time"] <= t and t <= _keyframes[i + 1]["time"]:
				a = _keyframes[i]
				b = _keyframes[i + 1]
				break

	var span: float = b["time"] - a["time"]
	var blend: float = 0.0 if span <= 0.0001 else clamp((t - a["time"]) / span, 0.0, 1.0)

	var blended: Dictionary = {}
	var a_transforms: Dictionary = a["transforms"]
	var b_transforms: Dictionary = b["transforms"]
	for node_name in a_transforms.keys():
		var ta: Transform3D = a_transforms[node_name]
		var tb: Transform3D = b_transforms.get(node_name, ta)
		var origin: Vector3 = ta.origin.lerp(tb.origin, blend)
		var qa := ta.basis.get_rotation_quaternion()
		var qb := tb.basis.get_rotation_quaternion()
		var basis := Basis(qa.slerp(qb, blend))
		blended[node_name] = Transform3D(basis, origin)
	_apply_transforms(blended)

func _apply_transforms(transforms: Dictionary) -> void:
	for node_name in transforms.keys():
		var node: Node3D = rig_controller.find_node(node_name)
		if node != null:
			node.transform = transforms[node_name]
	_resync_limb_targets_from_current_pose()
	var current_selection: String = rig_controller.selected_component
	if current_selection != "":
		_on_component_selected(current_selection)
	_refresh_all_pole_handles()

func _on_save_file_requested(path: String, anim_name: String, pose_only: bool = false) -> void:
	var content: String
	if pose_only or _keyframes.is_empty():
		content = MdlExporter.export_pose($Rig, anim_name)
	else:
		content = MdlExporter.export_animation($Rig, anim_name, _anim_length, _keyframes)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		side_panel.set_status("Cannot save %s: %s" % [path, error_string(FileAccess.get_open_error())])
		return
	file.store_string(content)
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		side_panel.set_status("Save failed: %s" % error_string(write_error))
		return
	side_panel.set_status("Saved: %s" % path)

# ---------------------------------------------------------------------------
# Transform panel
# ---------------------------------------------------------------------------

func _basis_to_euler_degrees(basis: Basis) -> Vector3:
	var e := basis.get_euler()
	return Vector3(rad_to_deg(e.x), rad_to_deg(e.y), rad_to_deg(e.z))

func _euler_degrees_to_basis(v: Vector3) -> Basis:
	return Basis.from_euler(Vector3(deg_to_rad(v.x), deg_to_rad(v.y), deg_to_rad(v.z)))

## Keeps the panel's fields in sync with whatever the gizmo/handles are
## doing live, unless the user is actively typing in one of them.
func _refresh_transform_panel() -> void:
	var panel: VBoxContainer = side_panel.transform_panel
	if not panel.visible or panel.any_field_focused():
		return
	if rig_controller.selected_components.size() > 1:
		panel.set_position_fields(_translation_anchor())
		panel.set_rotation_fields(_basis_to_euler_degrees(gizmo.target.basis))
		return
	var component_id: String = rig_controller.selected_component
	if component_id == "":
		return

	var is_ik := false
	for comp in RigComponents.definitions():
		if comp.id == component_id:
			is_ik = comp.is_ik
			break

	if is_ik:
		var chain: Array[Node3D] = rig_controller.get_chain_nodes(component_id)
		if chain.size() == 3 and _limb_targets.has(component_id):
			panel.set_position_fields(_limb_targets[component_id]["target"])
			panel.set_rotation_fields(_basis_to_euler_degrees(chain[2].basis))
	else:
		if component_id == "pelvis":
			var root_dummy: Node3D = rig_controller.find_node("rootdummy")
			if root_dummy != null:
				panel.set_position_fields(root_dummy.global_position)
		var node: Node3D = rig_controller.get_component_root_node(component_id)
		if node != null:
			if component_id != "pelvis":
				panel.set_position_fields(node.global_position)
			panel.set_rotation_fields(_basis_to_euler_degrees(node.basis))

func _on_panel_position_changed(v: Vector3) -> void:
	_push_undo_snapshot()
	var component_id: String = rig_controller.selected_component
	if rig_controller.selected_components.size() > 1 or (_active_ik_component == "" and component_id != "pelvis"):
		_begin_selection_translation()
		_translate_selection(v)
		return
	if component_id == "pelvis":
		var root_dummy: Node3D = rig_controller.find_node("rootdummy")
		if root_dummy != null:
			root_dummy.global_position = v
		if _root_height_handle != null:
			_root_height_handle.global_position = v
	elif component_id in ATTACHMENT_COMPONENT_IDS:
		var node: Node3D = rig_controller.get_component_root_node(component_id)
		if node != null:
			node.global_position = v
		if _attachment_translate_handle != null:
			_attachment_translate_handle.global_position = v
	elif _active_ik_component != "":
		_limb_targets[_active_ik_component]["target"] = v
		if _target_handle != null:
			_target_handle.global_position = v

func _on_panel_rotation_changed(v: Vector3) -> void:
	_push_undo_snapshot()
	_rotate_selection(_euler_degrees_to_basis(v))

func _rotate_selection(value: Basis) -> void:
	if gizmo.target == null: return
	var delta: Basis = gizmo.target.basis.inverse() * value
	if rig_controller.selected_components.size() > 1:
		for node in rig_controller.selection_roots(): node.basis = node.basis * delta
	else:
		gizmo.target.basis = value
	_resync_limb_targets_from_current_pose()

func _on_open_file_requested(path: String, memory_slot: int = -1) -> void:
	if memory_slot >= 0:
		if mdl_bank != null and mdl_bank.recognizes(path):
			mdl_bank.open_memory_bank(path, memory_slot)
		else:
			_import_pose_memory(path, memory_slot)
		return
	if mdl_bank == null or not mdl_bank.loading_clip:
		_pose_memory_pending_slot = memory_slot
	if mdl_bank != null and not mdl_bank.loading_clip:
		if mdl_bank.recognizes(path):
			mdl_bank.open_bank(path)
			return
		mdl_bank.active_clip = ""
	if qol != null: qol.release_constraints()
	_push_undo_snapshot()
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		side_panel.set_status("Error: could not read file.")
		return
	var text := file.get_as_text()
	file.close()

	# Missing tracks use the model's rest pose, never an unrelated previous clip.
	var previous_pose: Dictionary = MdlExporter.capture_pose($Rig)
	for node in _rest_transforms:
		if is_instance_valid(node): node.transform = _rest_transforms[node]
	var result = MdlImporter.parse(text, $Rig)
	if result == null:
		_apply_transforms(previous_pose)
		side_panel.set_status("Error: could not parse file (no 'newanim' found).")
		return

	side_panel.timeline.clear_selection()
	_keyframes = result["keyframes"]
	_anim_length = result["length"]
	side_panel.set_anim_name(result["anim_name"])
	side_panel.set_duration(_anim_length)
	_refresh_timeline_markers()
	side_panel.timeline.set_current_time(0.0)
	_apply_pose_at_time(0.0)
	side_panel.set_status("Opened: %s" % path)
	if _pose_memory_pending_slot >= 0:
		var slot := _pose_memory_pending_slot
		_pose_memory_pending_slot = -1
		_on_pose_memory_save(slot)
		_pose_memory_clips[slot] = {"keyframes": _keyframes.duplicate(true), "length": _anim_length}
		side_panel.set_status("Animation saved to slot %d." % (slot + 1))



# ---------------------------------------------------------------------------
# Retargeting
#
# Simplified flow: load a source model+animation, see it as a red skeleton
# overlay synced to the MAIN timeline (same one used for hand-posed
# animation). Scrub to a comfortable frame, pose the real rig by hand to
# match the overlay, then press Bake — it reads the source's pose and the
# rig's current pose at that exact frame, back-computes the rotation
# offset that explains the difference, and bakes the whole source
# animation through that offset onto the timeline.
# ---------------------------------------------------------------------------

var _retarget_config: Dictionary = {}
var _retarget_config_path: String = ""
var _retarget_model_path: String = ""
var _retarget_anim_scene: Node3D = null
var _show_retarget_overlay: bool = false
var _retarget_lock: Dictionary = {} # from Retargeter.lock_offsets(), empty until "Lock" is pressed
var _retarget_lock_time: float = 0.0
var _retarget_flip_180: bool = false

func _on_retarget_cfg_import_requested(config_path: String) -> void:
	_retarget_config_path = config_path
	_retarget_config = RetargetConfig.load_from_file(config_path)
	if _retarget_config.is_empty():
		side_panel.bone_config_panel.set_status("Couldn't load config: %s" % config_path)
		return
	side_panel.bone_config_panel.set_status("Config '%s' loaded (%d bones mapped)." % [
		_retarget_config.get("prefab_name", "?"), _retarget_config.get("bone_map", {}).size()
	])
	side_panel.bone_config_panel.set_bone_map(RetargetConfig.NWN_NODES, _retarget_config.get("bone_map", {}))
	side_panel.bone_config_panel.set_root_scale(_retarget_config.get("root_scale", 1.0))

## "Load animation": the model+animation file to retarget. Drives the red
## overlay (synced to the main timeline), supplies the bone names for the
## Bone configuration dropdowns, and is what Bake samples from.
func _on_retarget_load_animation_requested(path: String) -> void:
	var scene: Node3D = Retargeter._load_glb(path)
	if scene == null:
		side_panel.set_status("Could not load animation file.")
		return
	var skeleton: Skeleton3D = Retargeter._find_skeleton(scene)
	if skeleton == null:
		scene.queue_free()
		side_panel.set_status("No Skeleton3D found in that file.")
		return

	if _retarget_anim_scene != null:
		_retarget_anim_scene.queue_free()
	add_child(scene)
	_retarget_anim_scene = scene
	_retarget_model_path = path

	# seek() only applies a pose once current_animation is set — without an
	# initial play(), every later seek() on this player would silently do
	# nothing and the overlay/bake would always read the bind pose.
	var anim_player := Retargeter._find_animation_player(scene)
	if anim_player != null:
		var anim_names := Retargeter.motion_animation_names(anim_player)
		if not anim_names.is_empty():
			anim_player.play(anim_names[0])
			anim_player.seek(0.0, true)
			anim_player.pause()

	var bone_names: Array = []
	for i in range(skeleton.get_bone_count()):
		bone_names.append(skeleton.get_bone_name(i))
	side_panel.bone_config_panel.set_available_bones(bone_names)

	# The overlay is the whole point of loading an animation — show it right
	# away instead of making the user remember to flip the toggle. Set the
	# button's visual state without relying on the toggled signal firing,
	# then drive the actual show/sync logic directly.
	_set_overlay_source("retarget")
	side_panel.set_overlay_active(true)
	_on_retarget_overlay_toggled(true)
	side_panel.set_status("Animation loaded: %s (%d bones)." % [path.get_file(), skeleton.get_bone_count()])

## Which motion source currently owns the reference-skeleton overlay:
## "" (none yet), "retarget" (red glb skeleton) or "ai" (green landmarks).
## The unified Skel toggle routes here.
var _overlay_source: String = ""

func _set_overlay_source(source: String) -> void:
	_overlay_source = source
	# Only one reference skeleton on screen at a time
	if source == "ai":
		_show_retarget_overlay = false
		red_visualizer.visible = false
	elif source == "retarget":
		green_visualizer.visible = false

func _bind_wizard_overlay(panel: Control, source: String) -> void:
	panel.visibility_changed.connect(func():
		if panel.visible:
			_set_overlay_source(source)
		side_panel.set_overlay_active(panel.visible)
		_on_overlay_toggled(panel.visible))

func _on_overlay_toggled(enabled: bool) -> void:
	_nwn_skeleton.visible = enabled
	if enabled: _update_nwn_skeleton()
	match _overlay_source:
		"ai":
			green_visualizer.visible = enabled
		"retarget":
			_on_retarget_overlay_toggled(enabled)
		_:
			if enabled:
				side_panel.set_status("NWN skeleton overlay")

## Show/hide the red skeleton overlay (retarget source).
func _on_retarget_overlay_toggled(enabled: bool) -> void:
	_show_retarget_overlay = enabled
	if not enabled:
		red_visualizer.visible = false
		return
	if _retarget_anim_scene == null:
		side_panel.set_status("Load an animation first.")
		return
	_sync_retarget_overlay(side_panel.timeline.current_time)

## Seeks the loaded source animation to the same time as the main timeline
## (clamped to the source's own length) and redraws the red overlay there.
## Called on every scrub/play tick while the overlay is enabled.
func _sync_retarget_overlay(t: float) -> void:
	if not _show_retarget_overlay or _retarget_anim_scene == null:
		return
	var anim_player := Retargeter._find_animation_player(_retarget_anim_scene)
	if anim_player == null:
		return
	var anim_names := Retargeter.motion_animation_names(anim_player)
	if anim_names.is_empty():
		return
	var length: float = anim_player.get_animation(anim_names[0]).length
	var seek_t: float = clamp(t, 0.0, length) if length > 0.0 else 0.0
	anim_player.seek(seek_t, true)
	var skeleton := Retargeter._find_skeleton(_retarget_anim_scene)
	if skeleton != null:
		_refresh_red_visualizer(skeleton)

## Root scale only changes how far rootdummy travels during Bake, but the
## overlay should still visibly reflect it live — otherwise the spinbox
## looks like it does nothing while you're tuning it against the rig.
func _on_retarget_root_scale_changed(value: float) -> void:
	if _retarget_anim_scene != null:
		_retarget_anim_scene.scale = Vector3.ONE * value
	_sync_retarget_overlay(side_panel.timeline.current_time)

## Rotates the loaded SOURCE glb 180° — and unlike the very first version of
## this toggle, it's no longer just cosmetic: Retargeter now reads each
## source bone's world rotation/position through the Skeleton3D node's own
## global_transform, so this root-level flip propagates into both Lock
## (captured immediately, since the overlay's skeleton already has it) and
## Bake (passed through explicitly, since bake() reloads the glb fresh and
## has to re-apply the same rotation for the math to stay consistent).
func _on_retarget_flip_180_toggled(enabled: bool) -> void:
	_retarget_flip_180 = enabled
	if _retarget_anim_scene != null:
		_apply_glb_source_xform()
	_sync_retarget_overlay(side_panel.timeline.current_time)

## Draws the red overlay. Once the Bone configuration table has at least one
## mapped bone, only those are shown (skipping up past unmapped ancestors so
## lines still connect to the nearest joint that's actually shown — fingers/
## tail/hair/weapon-attach dummies on a full source rig would otherwise bury
## the handful of joints that matter). Before anything is mapped yet, show
## every bone instead — otherwise there'd be nothing to look at while
## actually doing the configuring.
func _refresh_red_visualizer(skeleton: Skeleton3D) -> void:
	var mapped_names: Dictionary = {}
	for source_bone in side_panel.bone_config_panel.get_bone_map().values():
		if source_bone != "":
			mapped_names[source_bone] = true
	var filter_to_mapped: bool = not mapped_names.is_empty()

	var entries: Array = []
	for i in range(skeleton.get_bone_count()):
		var bone_name: String = skeleton.get_bone_name(i)
		if filter_to_mapped and not mapped_names.has(bone_name):
			continue
		var pos: Vector3 = skeleton.global_transform * skeleton.get_bone_global_pose(i).origin
		var parent_idx: int = skeleton.get_bone_parent(i)
		if filter_to_mapped:
			while parent_idx >= 0 and not mapped_names.has(skeleton.get_bone_name(parent_idx)):
				parent_idx = skeleton.get_bone_parent(parent_idx)
		var parent_pos: Variant = null
		if parent_idx >= 0:
			parent_pos = skeleton.global_transform * skeleton.get_bone_global_pose(parent_idx).origin
		entries.append({"name": bone_name, "position": pos, "parent_position": parent_pos})
	red_visualizer.build(entries)
	red_visualizer.visible = true

## Bake: first "locks" the current hand-posed match (records, for every
## mapped node, a fixed WORLD-SPACE offset between the source bone's current
## orientation and the rig's current orientation — exactly a Maya "orient
## constraint with maintain offset"), then immediately replays the whole
## source animation maintaining that same offset, frame by frame. Used to be
## two separate buttons; pressing Bake without first pressing Lock makes no
## sense on its own, so Bake just does both in one step now.
func _on_retarget_bake_requested() -> void:
	if _retarget_config.is_empty():
		side_panel.set_status("Load a bone configuration first.")
		return
	if _retarget_anim_scene == null:
		side_panel.set_status("Load an animation first.")
		return
	var skeleton: Skeleton3D = Retargeter._find_skeleton(_retarget_anim_scene)
	var anim_player: AnimationPlayer = Retargeter._find_animation_player(_retarget_anim_scene)
	if skeleton == null or anim_player == null:
		return
	var anim_names := Retargeter.motion_animation_names(anim_player)
	if anim_names.is_empty():
		return

	var bone_map: Dictionary = side_panel.bone_config_panel.get_bone_map()
	var length: float = anim_player.get_animation(anim_names[0]).length
	var source_fps: float = _retarget_config.get("source_fps", 30.0)
	# Snap to the same fixed-fps grid bake()'s loop samples (t = frame_i /
	# source_fps) — otherwise the timeline's continuous, mouse-dragged time
	# almost never lands exactly on a baked keyframe, so the pose shown
	# right after Bake is a SLERP/LERP interpolation between two nearby
	# keyframes instead of the exact match you just locked in, which can
	# visibly differ from it and look like an unexplained snap.
	var raw_time: float = clamp(side_panel.timeline.current_time, 0.0, length)
	_retarget_lock_time = clamp(round(raw_time * source_fps) / source_fps, 0.0, length)
	anim_player.seek(_retarget_lock_time, true)

	var world_rotations := {}
	var world_positions := {}
	for nwn_node_name in bone_map.keys():
		var node: Node3D = rig_controller.find_node(nwn_node_name)
		if node != null:
			world_rotations[nwn_node_name] = node.global_basis.get_rotation_quaternion()
			world_positions[nwn_node_name] = node.global_position

	_retarget_config["bone_map"] = bone_map
	_retarget_lock = Retargeter.lock_offsets(skeleton, bone_map, world_rotations, world_positions)

	var rest_by_name: Dictionary = {}
	for node in _rest_transforms.keys():
		if is_instance_valid(node):
			rest_by_name[node.name] = _rest_transforms[node]

	var result: Dictionary = Retargeter.bake(
		self,
		_retarget_model_path,
		bone_map,
		rest_by_name,
		_retarget_config.get("source_fps", 30.0),
		side_panel.bone_config_panel.get_root_scale(),
		_retarget_lock,
		_retarget_flip_180,
		side_panel.get_source_rotation("glb"),
		side_panel.get_source_xform("glb").origin
	)
	if result.has("error"):
		side_panel.set_status("Bake failed: %s" % result["error"])
		return

	_push_undo_snapshot()
	side_panel.timeline.clear_selection()
	_keyframes = result["keyframes"]
	_anim_length = result["length"]
	side_panel.set_anim_name(result["anim_name"])
	side_panel.set_duration(_anim_length)
	_refresh_timeline_markers()
	# Stay on the locked frame instead of snapping to t=0: the pose shown
	# right before Bake (your hand-posed match) and right after should be
	# the SAME pose, continuously — jumping to frame 0 instead would show a
	# different, unrelated pose from elsewhere in the clip and look like a
	# glitch even though the bake itself is correct.
	side_panel.timeline.set_current_time(_retarget_lock_time)
	_apply_pose_at_time(_retarget_lock_time)
	side_panel.set_status("Baked %d keyframes (locked at t=%.2fs)." % [_keyframes.size(), _retarget_lock_time])

# ---------------------------------------------------------------------------
# AI Pose
# ---------------------------------------------------------------------------

var _ai_client: Node = null
var _ai_pending_image_path: String = ""
var _ai_pending_landmarks: Array = []
var _ai_scale_factor: float = 1.0
var _ai_origin: Vector3 = Vector3.ZERO
# True once scale/origin were measured for the current detection; cleared on
# every new image/video so the next overlay recalibrated from the rig.
var _ai_overlay_calibrated: bool = false
# Which AI wizard currently owns the green overlay ("image" or "video") —
# picks whose SOURCE TRANSFORM controls drive the preview and the apply.
var _ai_wizard: String = "image"

## Live update of the reference skeleton when the user edits a SOURCE
## TRANSFORM control. The green visualizer's node transform IS the user
## transform (its content stays in untransformed coordinates); the glb
## source gets it on the loaded scene root so lock/bake see it too.
func _on_source_xform_changed(kind: String) -> void:
	match kind:
		"image", "video":
			if kind == _ai_wizard:
				if kind == "video" and _video_previewed:
					_preview_video_frame()
				elif kind == "video":
					if not _video_overlay_params.is_empty():
						_video_overlay_params.user_xform = side_panel.get_source_xform(kind)
					_sync_video_pose_overlay(side_panel.timeline.current_time)
				else:
					_show_ai_landmark_overlay(_ai_pending_landmarks)
		"glb":
			_apply_glb_source_xform()

func _apply_glb_source_xform() -> void:
	if _retarget_anim_scene == null:
		return
	var rot: Vector3 = side_panel.get_source_rotation("glb")
	rot.y += PI if _retarget_flip_180 else 0.0
	_retarget_anim_scene.rotation = rot
	_retarget_anim_scene.position = side_panel.get_source_xform("glb").origin
	_sync_retarget_overlay(side_panel.timeline.current_time)

# Seven session-only slots: Save stores a pose; Open stores a complete animation.
var _pose_memory: Array = [null, null, null, null, null, null, null]  # pose snapshots
var _pose_memory_names: Array[String] = ["", "", "", "", "", "", ""]
var _pose_memory_clips: Array = [null, null, null, null, null, null, null]
var _pose_memory_pending_slot: int = -1

func _on_pose_memory_open(slot: int) -> void:
	qol.open_library(slot)

func _import_pose_memory(path: String, slot: int) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		side_panel.set_status("Could not open animation for pose memory.")
		return
	# Parse against a separate rest rig, never reset the live scene.
	var reference: Node3D = load(_current_model_path).instantiate()
	var result = MdlImporter.parse(file.get_as_text(), reference)
	reference.free()
	if result == null or result.keyframes.is_empty():
		side_panel.set_status("No valid animation found; pose memory unchanged.")
		return
	_pose_memory[slot] = result.keyframes[0].transforms.duplicate(true)
	_pose_memory_names[slot] = result.anim_name
	_pose_memory_clips[slot] = {"keyframes": result.keyframes.duplicate(true), "length": result.length}
	side_panel.set_pose_memory_slot_name(slot, result.anim_name)
	side_panel.set_pose_memory_slot_filled(slot, true)
	side_panel.set_status("Stored %s in slot %d. Main animation unchanged." % [result.anim_name,slot+1])

func _on_pose_memory_save(slot: int) -> void:
	_pose_memory_clips[slot] = null
	_pose_memory[slot] = MdlExporter.capture_pose($Rig)
	_pose_memory_names[slot] = side_panel.get_anim_name() if not side_panel.get_anim_name().is_empty() else "Untitled pose"
	side_panel.set_pose_memory_slot_name(slot, _pose_memory_names[slot])
	side_panel.set_pose_memory_slot_filled(slot, true)
	side_panel.set_status("Pose saved to slot %d." % (slot + 1))

func _on_pose_memory_load(slot: int) -> void:
	if _pose_memory[slot] == null:
		return
	var snap: Dictionary = _pose_memory[slot]
	_push_undo_snapshot()
	_on_play_toggled(false)
	rig_controller.deselect()
	if qol != null: qol.release_constraints()
	_apply_transforms(snap)
	side_panel.set_status("Pose loaded from slot %d. Press Set to save at the current time." % (slot + 1))

# Bulk processing state
var _bulk_queue: Array = []       # Array of file paths remaining
var _bulk_output_dir: String = ""
var _bulk_total: int = 0
var _bulk_done: int = 0

func _on_ai_image_selected(path: String) -> void:
	_ai_pending_image_path = path
	_ai_pending_landmarks = []
	_ai_overlay_calibrated = false
	_ai_wizard = "image"
	side_panel.set_ai_server_status("Analyzing image...")
	side_panel.set_ai_apply_enabled(false)
	_ai_client.detect(path)

func _on_ai_pose_received(world_landmarks: Array) -> void:
	if _bulk_total > 0:
		_bulk_on_pose_received(world_landmarks)
		return
	_ai_pending_landmarks = world_landmarks
	side_panel.set_ai_server_status("Pose detected. Press Apply Pose.")
	side_panel.set_ai_apply_enabled(true)
	_set_overlay_source("ai")
	_show_ai_landmark_overlay(world_landmarks)
	side_panel.set_overlay_active(true)

# MediaPipe skeleton connections (from_idx, to_idx) — the standard 33-point
# pose topology, enough to draw a recognizable body outline as a debug overlay.
const MP_CONNECTIONS := [
	[11, 12], # shoulders
	[11, 13], [13, 15], # left arm
	[12, 14], [14, 16], # right arm
	[11, 23], [12, 24], # torso sides
	[23, 24], # hips
	[23, 25], [25, 27], # left leg
	[24, 26], [26, 28], # right leg
	[0, 11], [0, 12],   # head to shoulders (approximation)
]

func _show_ai_landmark_overlay(world_landmarks: Array) -> void:
	if _ai_wizard == "image" and side_panel.image_pose_panel.get_node("Scroll/Body/SidePose").button_pressed:
		world_landmarks = AIPoseApplier.side_image_landmarks(world_landmarks)
	green_visualizer.clear()

	if world_landmarks.is_empty():
		green_visualizer.visible = false
		return

	# The user's SOURCE TRANSFORM lives on the visualizer node itself, so
	# the content below stays in untransformed coordinates and the preview
	# rotates/moves live as the spinboxes change.
	green_visualizer.transform = side_panel.get_source_xform(_ai_wizard)

	# Scale and anchor are measured from the rig ONCE per detection and then
	# cached: Apply pose moves the rig (grounding lowers the hips), so
	# re-measuring here on every render would drag the preview along with the
	# applied pose — toggling ground/apply repeatedly made the overlay drift
	# to the floor permanently.
	if not _ai_overlay_calibrated:
		var left_hip_node: Node3D = rig_controller.find_node("lthigh_g")
		var right_hip_node: Node3D = rig_controller.find_node("rthigh_g")
		var rig_hip_center := Vector3.ZERO
		if left_hip_node != null and right_hip_node != null:
			rig_hip_center = (left_hip_node.global_position + right_hip_node.global_position) * 0.5
		elif left_hip_node != null:
			rig_hip_center = left_hip_node.global_position

		_ai_scale_factor = AIPoseApplier.estimate_scale(world_landmarks, $Rig)
		_ai_origin = rig_hip_center
		_ai_overlay_calibrated = true

	green_visualizer.transform = Transform3D.IDENTITY
	var positions: Array[Vector3]
	if _ai_wizard == "video" and not _video_overlay_params.is_empty():
		var p := _video_overlay_params
		positions = AIPoseApplier.landmark_positions(world_landmarks, p.scale, p.origin,
			p.pre_rotation, true, p.user_xform, p.foot_y)
	else:
		positions = AIPoseApplier.landmark_positions(world_landmarks, _ai_scale_factor, _ai_origin,
			Quaternion.IDENTITY, _ai_wizard == "video" or side_panel.is_ai_ground_enabled(),
			side_panel.get_source_xform(_ai_wizard))

	# Build joint entries
	var entries: Array = []
	for i in range(positions.size()):
		var lm = world_landmarks[i]
		if lm.get("visibility", 1.0) < 0.3:
			continue
		entries.append({"name": lm.get("name", str(i)), "position": positions[i], "parent_position": null})

	# Add bone lines from connections
	var entry_map: Dictionary = {}
	for e in entries:
		entry_map[e["name"]] = e

	for conn in MP_CONNECTIONS:
		var a_idx: int = conn[0]
		var b_idx: int = conn[1]
		if a_idx >= positions.size() or b_idx >= positions.size():
			continue
		var vis_a: float = world_landmarks[a_idx].get("visibility", 1.0)
		var vis_b: float = world_landmarks[b_idx].get("visibility", 1.0)
		if vis_a < 0.3 or vis_b < 0.3:
			continue
		var name_a: String = world_landmarks[a_idx].get("name", str(a_idx))
		if entry_map.has(name_a):
			entry_map[name_a]["parent_position"] = positions[b_idx]

	green_visualizer.build(entries)
	green_visualizer.visible = true

func _on_ai_pose_failed(error: String) -> void:
	if _bulk_total > 0:
		side_panel.set_bulk_progress("Error on %s: %s" % [_ai_pending_image_path.get_file(), error])
		_bulk_done += 1
		_bulk_process_next()
		return
	side_panel.set_ai_server_status("Error: %s" % error)
	side_panel.set_ai_apply_enabled(false)
	green_visualizer.visible = false

func _on_ai_apply_pose() -> void:
	if _ai_pending_landmarks.is_empty():
		side_panel.set_status("No pose detected yet — load an image first.")
		return
	_push_undo_snapshot()
	_on_play_toggled(false)
	if qol != null: qol.release_constraints()
	rig_controller.deselect()

	var side_pose: bool = side_panel.image_pose_panel.get_node("Scroll/Body/SidePose").button_pressed
	var image_landmarks := AIPoseApplier.side_image_landmarks(_ai_pending_landmarks) if side_pose else _ai_pending_landmarks
	var data := AIPoseApplier.compute(image_landmarks, $Rig, _ai_scale_factor, _ai_origin,
		Quaternion.IDENTITY, {}, side_panel.is_ai_ground_enabled(), side_panel.get_source_xform("image"), 0.25 if side_pose else 0.4)
	if data.is_empty():
		side_panel.set_status("Could not compute pose from landmarks.")
		return

	# Apply IK targets — same as dragging the yellow/foot handles by hand
	var ik_targets: Dictionary = data.get("ik_targets", {})
	for comp_id in ik_targets:
		if _limb_targets.has(comp_id):
			_limb_targets[comp_id]["target"] = ik_targets[comp_id]["target"]
			_limb_targets[comp_id]["pole"]   = ik_targets[comp_id]["pole"]

	# Apply actual image hand orientation through the same pins used by IK.
	var hand_bases := AIPoseApplier.image_hand_bases(data)
	for name in hand_bases:
		_limb_targets[END_BONE_COMPONENT[name]].end_basis = hand_bases[name]

	# Apply FK rotations (pelvis, torso, head) directly onto the bone nodes
	var fk_rotations: Dictionary = data.get("fk_rotations", {})
	for bone_name in fk_rotations:
		var node: Node3D = rig_controller.find_node(bone_name)
		if node != null:
			node.quaternion = fk_rotations[bone_name]

	# Move pelvis/rootdummy if hip position was computed
	var root_pos: Variant = data.get("root_position", null)
	if root_pos != null:
		var rootdummy: Node3D = rig_controller.find_node("rootdummy")
		if rootdummy != null:
			rootdummy.global_position = root_pos

	if side_panel.image_pose_panel.get_node("Scroll/Body/ImageTwoHandGrip").button_pressed:
		_apply_image_two_hand_grip(hand_bases)

	var sel: String = rig_controller.selected_component
	if sel != "":
		_on_component_selected(sel)

	# Deliberately NOT touching the green overlay here: it follows the image
	# panel's open/close lifecycle, and after Apply it stays up as a debug
	# reference to compare the applied pose against the detected landmarks.
	var n_ik := ik_targets.size()
	var n_fk := fk_rotations.size()
	side_panel.set_ai_server_status("Applied: %d/4 limbs. %s" % [n_ik, "Side pose: verify hidden joints." if side_pose else "Enable Side pose if an occluded limb was skipped."])


func _apply_image_two_hand_grip(bases: Dictionary) -> void:
	if not bases.has("rhand_g") or not bases.has("lhand_g"): return
	var right: Node3D = rig_controller.find_node("rhand_g")
	var left: Node3D = rig_controller.find_node("lhand_g")
	var rattach: Node3D = rig_controller.find_node("rhand")
	var lattach: Node3D = rig_controller.find_node("lhand")
	if right == null or left == null or rattach == null or lattach == null: return
	var right_local: Transform3D = right.global_transform.affine_inverse() * rattach.global_transform
	var left_local: Transform3D = left.global_transform.affine_inverse() * lattach.global_transform
	var rb: Basis = bases.rhand_g
	var lb: Basis = bases.lhand_g
	var blade := (rb * right_local.basis * Vector3.FORWARD).normalized()
	var left_blade := (lb * left_local.basis * Vector3.FORWARD).normalized()
	lb = Basis(Quaternion(left_blade,blade)) * lb
	var grip: Vector3 = _limb_targets.right_arm.target + rb * right_local.origin
	# Keep the shared grip reachable by both arms, without changing bone lengths.
	var offsets := {"right_arm": -(rb * right_local.origin), "left_arm": -blade * .11 - lb * left_local.origin}
	for iteration in 12:
		for id in ["right_arm", "left_arm"]:
			var chain: Array = rig_controller.get_chain_nodes(id)
			var reach: float = (chain[0].global_position.distance_to(chain[1].global_position) + chain[1].global_position.distance_to(chain[2].global_position)) * .97
			var delta: Vector3 = grip + offsets[id] - chain[0].global_position
			if delta.length() > reach: grip -= delta.normalized() * (delta.length()-reach)
	_limb_targets.right_arm.target = grip + offsets.right_arm
	_limb_targets.left_arm.target = grip + offsets.left_arm
	_limb_targets.left_arm.end_basis = lb


# Maps the AI applier's end-bone names onto the IK component whose end_basis
# pin controls that bone's world orientation.
const END_BONE_COMPONENT := {
	"rhand_g": "right_arm",
	"lhand_g": "left_arm",
	"rfoot_g": "right_leg",
	"lfoot_g": "left_leg",
}
const BULK_IMAGE_EXTENSIONS := ["png", "jpg", "jpeg"]

func _on_ai_bulk_requested(input_dir: String, output_dir: String) -> void:
	var dir := DirAccess.open(input_dir)
	if dir == null:
		side_panel.set_status("Could not open folder: %s" % input_dir)
		return

	_bulk_queue = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir():
			var ext := fname.get_extension().to_lower()
			if ext in BULK_IMAGE_EXTENSIONS:
				_bulk_queue.append(input_dir.path_join(fname))
		fname = dir.get_next()
	dir.list_dir_end()
	_bulk_queue.sort()

	if _bulk_queue.is_empty():
		side_panel.set_status("No images found in folder.")
		return

	_bulk_output_dir = output_dir
	_bulk_total = _bulk_queue.size()
	_bulk_done = 0
	side_panel.set_bulk_running(true)
	side_panel.set_bulk_progress("0 / %d" % _bulk_total)
	_bulk_process_next()

func _bulk_process_next() -> void:
	if _bulk_queue.is_empty():
		side_panel.set_bulk_running(false)
		side_panel.set_bulk_progress("Done: %d animations saved." % _bulk_done)
		side_panel.set_status("Bulk complete: %d animations saved to %s" % [_bulk_done, _bulk_output_dir])
		_bulk_total = 0
		return

	var path: String = _bulk_queue.pop_front()
	side_panel.set_bulk_progress("%d / %d — %s" % [_bulk_done, _bulk_total, path.get_file()])
	_ai_pending_image_path = path
	_ai_pending_landmarks = []
	_ai_client.detect(path)

func _bulk_on_pose_received(world_landmarks: Array) -> void:
	# Compute scale/origin same as single-image flow
	_show_ai_landmark_overlay(world_landmarks)
	var data := AIPoseApplier.compute(world_landmarks, $Rig, _ai_scale_factor, _ai_origin)
	if data.is_empty():
		_bulk_done += 1
		_bulk_process_next()
		return

	# Reset rig to rest before applying each pose
	for node in _rest_transforms.keys():
		if is_instance_valid(node):
			node.transform = _rest_transforms[node]
	_init_default_limb_targets()

	# Apply IK targets
	for comp_id in data.get("ik_targets", {}).keys():
		if _limb_targets.has(comp_id):
			_limb_targets[comp_id]["target"] = data["ik_targets"][comp_id]["target"]
			_limb_targets[comp_id]["pole"]   = data["ik_targets"][comp_id]["pole"]

	# Apply FK
	for bone_name in data.get("fk_rotations", {}).keys():
		var node: Node3D = rig_controller.find_node(bone_name)
		if node != null:
			node.quaternion = data["fk_rotations"][bone_name]

	# Root position
	var root_pos: Variant = data.get("root_position", null)
	if root_pos != null:
		var rootdummy: Node3D = rig_controller.find_node("rootdummy")
		if rootdummy != null:
			rootdummy.global_position = root_pos

	# Zero hands
	for hand_name in ["rhand_g", "lhand_g"]:
		var hand: Node3D = rig_controller.find_node(hand_name)
		if hand != null:
			hand.basis = Basis.IDENTITY

	# Let the IK solver run for one frame before exporting
	await get_tree().process_frame

	# Export and save
	var anim_name: String = _ai_pending_image_path.get_file().get_basename()
	var content := MdlExporter.export_pose($Rig, anim_name)
	var out_path := _bulk_output_dir.path_join(anim_name + ".txt")
	var file := FileAccess.open(out_path, FileAccess.WRITE)
	if file != null:
		file.store_string(content)
		file.close()
		_bulk_done += 1
	else:
		side_panel.set_bulk_progress("Error saving: %s" % out_path)

	green_visualizer.visible = false
	_bulk_process_next()

func _on_retarget_save_config_requested() -> void:
	if _retarget_config_path == "":
		side_panel.bone_config_panel.prompt_save_as()
		return
	_save_retarget_config_to(_retarget_config_path)

func _on_retarget_save_as_chosen(path: String) -> void:
	_retarget_config_path = path
	_save_retarget_config_to(path)

# ---------------------------------------------------------------------------
# Video pose extraction
# ---------------------------------------------------------------------------
var _video_client: Node = null
var _video_panel: Panel = null
var _video_extracted_frames: Array = []
var _video_extracted_duration: float = 0.0

func _setup_video_pose_panel() -> void:
	_video_panel = $SidePanel/VideoPosePanel
	_video_client = VideoPoseClientScript.new()
	_video_client.name = "VideoPoseClient"
	add_child(_video_client)
	_video_client.extraction_done.connect(_on_video_extraction_done)
	_video_client.extraction_failed.connect(_on_video_extraction_failed)

	var panel := _video_panel
	var body := panel.get_node("Scroll/Body")
	var simplify := CheckBox.new()
	simplify.name = "SimplifyPoses"
	simplify.text = "Keep key poses only"
	simplify.button_pressed = true
	simplify.tooltip_text = "Bake fewer keys by keeping the largest changes in movement"
	body.add_child(simplify)
	body.move_child(simplify,body.get_node("ExtractButton").get_index())
	var row := HBoxContainer.new()
	row.name = "KeyPoseRow"
	body.add_child(row)
	body.move_child(row,simplify.get_index()+1)
	var label := Label.new()
	label.text = "Max key poses"
	row.add_child(label)
	var count := SpinBox.new()
	count.name = "Count"
	count.min_value = 2
	count.max_value = 500
	count.value = 12
	row.add_child(count)
	simplify.toggled.connect(func(enabled): count.editable = enabled)

	panel.get_node("TitleRow/CloseButton").pressed.connect(func(): panel.visible = false)

	var load_btn: Button = panel.get_node("Scroll/Body/VideoRow/LoadVideoButton")
	var video_dialog: FileDialog = panel.get_node("VideoDialog")
	load_btn.pressed.connect(func(): video_dialog.popup_centered_ratio(0.7))
	video_dialog.file_selected.connect(_on_video_selected)

	panel.get_node("Scroll/Body/ExtractButton").pressed.connect(_on_video_extract_pressed)
	panel.get_node("Scroll/Body/ResultRow/PreviewButton").pressed.connect(func(): _preview_video_frame())
	panel.get_node("Scroll/Body/ResultRow/BakeButton").pressed.connect(_on_video_apply_to_timeline)
	# Re-run the preview when the feet offset changes, so the knob is live.
	panel.get_node("Scroll/Body/FootRow/FootSpin").value_changed.connect(func(_v):
		if _video_previewed:
			_preview_video_frame())

func _on_video_pose_open() -> void:
	_video_panel.visible = true

func _on_video_selected(path: String) -> void:
	_video_panel.get_node("Scroll/Body/VideoRow/VideoPathLabel").text = path.get_file()
	_video_panel.get_node("Scroll/Body/VideoRow/VideoPathLabel").set_meta("full_path", path)
	_video_panel.get_node("Scroll/Body/ExtractButton").disabled = false
	_video_panel.get_node("Scroll/Body/ResultRow").visible = false
	side_panel.set_status("Video loaded: %s" % path.get_file())

func _on_video_extract_pressed() -> void:
	var path_label: Label = _video_panel.get_node("Scroll/Body/VideoRow/VideoPathLabel")
	if not path_label.has_meta("full_path"):
		return
	var video_path: String = path_label.get_meta("full_path")
	var sample_fps: float = _video_panel.get_node("Scroll/Body/FpsRow/FpsSpin").value
	var smooth_window: int = int(_video_panel.get_node("Scroll/Body/SmoothRow/SmoothSpin").value)

	_video_panel.get_node("Scroll/Body/ExtractButton").disabled = true
	_video_panel.get_node("Scroll/Body/ResultRow").visible = false
	side_panel.set_status("Extracting poses from video... this may take a moment.")
	_video_extracted_frames = []

	_video_client.extract(video_path, sample_fps, smooth_window)

func _on_video_extraction_done(frames: Array, duration: float) -> void:
	_video_extracted_frames = frames
	_video_extracted_duration = duration
	_video_overlay_params = {}
	_ai_overlay_calibrated = false
	_ai_wizard = "video"
	_video_previewed = false
	_video_preview_params = {}
	_video_preview_data = {}
	var n := frames.size()
	_video_panel.get_node("Scroll/Body/ExtractButton").disabled = false
	_video_panel.get_node("Scroll/Body/ResultRow/ResultLabel").text = "%d poses (%.1fs)" % [n, duration]
	_video_panel.get_node("Scroll/Body/ResultRow").visible = true
	# The animation duration follows the video as soon as it's known — the
	# user shouldn't have to wait for Apply to see the timeline match.
	_anim_length = duration
	side_panel.set_duration(_anim_length)
	side_panel.set_status("Video: %d poses detected (%.1fs). Timeline set to %.1fs." % [n, duration, duration])
	# Render the overlay right away — _sync only runs on scrub/play, so
	# without this the skeleton stays invisible until the first scrub.
	_sync_video_pose_overlay(side_panel.timeline.current_time)

func _on_video_extraction_failed(error: String) -> void:
	side_panel.set_status("Video extraction error: %s" % error)
	_video_panel.get_node("Scroll/Body/ExtractButton").disabled = false

## Measures the rig and reads the Motion Calibration panel, producing every
## parameter the per-frame pose application needs. Resets the rig to rest
## (and waits one frame) so scale/origin/calibration are measured cleanly.
## Shared by the full bake AND the live calibration preview.
func _compute_video_bake_params() -> Dictionary:
	for node in _rest_transforms.keys():
		if is_instance_valid(node):
			node.transform = _rest_transforms[node]
	_init_default_limb_targets()
	await get_tree().process_frame

	# Compute scale and origin from the rig at rest — same method as single-image
	var lthigh: Node3D = rig_controller.find_node("lthigh_g")
	var rthigh: Node3D = rig_controller.find_node("rthigh_g")
	var rig_hip_center := Vector3.ZERO
	if lthigh != null and rthigh != null:
		rig_hip_center = (lthigh.global_position + rthigh.global_position) * 0.5

	# Median over several sampled frames also reduces first-frame detection noise.
	var scales: Array[float] = []
	for i in range(min(15, _video_extracted_frames.size())):
		scales.append(AIPoseApplier.estimate_scale(_video_extracted_frames[i]["world_landmarks"], $Rig))
	scales.sort()
	var scale_factor: float = scales[scales.size() / 2] if not scales.is_empty() else 1.0
	var origin := rig_hip_center

	# World tilt: auto-level on frame 1 (assumed grounded/standing).
	var first_landmarks: Array = _video_extracted_frames[0]["world_landmarks"]
	var pre_rotation: Quaternion = AIPoseApplier.compute_ground_alignment(first_landmarks)

	# Hand/foot orientation: auto first-frame calibration. Manual fixes come
	# from the Lock&Bake flow (Preview → adjust by hand → Bake), not knobs.
	var user_xform: Transform3D = side_panel.get_source_xform("video")
	var calibration: Dictionary = AIPoseApplier.compute_rest_calibration(
		first_landmarks, $Rig, scale_factor, origin, pre_rotation, user_xform)

	return {
		"scale": scale_factor,
		"origin": origin,
		"pre_rotation": pre_rotation,
		"calibration": calibration,
		"use_end_bones": true,
		"foot_y": _video_panel.get_node("Scroll/Body/FootRow/FootSpin").value,
		"user_xform": user_xform,
	}

## Applies one extracted video frame to the rig (IK targets, end-bone pins,
## FK rotations, root position) using the given bake parameters, plus the
## optional user corrections captured from a hand-adjusted preview frame.
## Returns the computed pose data so the preview can cache it for Lock&Bake.
func _apply_video_frame(landmarks: Array, p: Dictionary, extras: Dictionary = {}) -> Dictionary:
	# Reset rig to rest before computing the frame's pose
	for node in _rest_transforms.keys():
		if is_instance_valid(node):
			node.transform = _rest_transforms[node]
	_init_default_limb_targets()

	var data := AIPoseApplier.compute(landmarks, $Rig, p["scale"], p["origin"],
		p["pre_rotation"], p["calibration"], true, p["user_xform"])
	if data.is_empty():
		return {}

	var target_extra: Dictionary = extras.get("target", {})
	var end_extra: Dictionary = extras.get("end", {})
	var fk_extra: Dictionary = extras.get("fk", {})

	var ik_targets: Dictionary = data.get("ik_targets", {})
	for comp_id in ik_targets:
		if _limb_targets.has(comp_id):
			_limb_targets[comp_id]["target"] = ik_targets[comp_id]["target"] + (target_extra.get(comp_id, Vector3.ZERO) as Vector3)
			_limb_targets[comp_id]["pole"]   = ik_targets[comp_id]["pole"]

	# Panel knob: constant vertical correction on both feet targets
	var foot_y_offset: float = p["foot_y"]
	if foot_y_offset != 0.0:
		for leg_id in ["right_leg", "left_leg"]:
			if _limb_targets.has(leg_id):
				_limb_targets[leg_id]["target"].y += foot_y_offset

	# Hand/foot orientations go into the end_basis PIN, not onto the node:
	# the IK loop in _process re-pins chain[2] to end_basis every frame,
	# so that's the only write that survives. Skipped entirely when the
	# panel's auto-calibration is off (bones keep their rest orientation).
	if p["use_end_bones"]:
		var end_bases: Dictionary = data.get("end_world_bases", {})
		for bone_name in end_bases:
			var comp_id: String = END_BONE_COMPONENT.get(bone_name, "")
			if comp_id != "" and _limb_targets.has(comp_id):
				_limb_targets[comp_id]["end_basis"] = (end_bases[bone_name] as Basis) \
					* Basis(end_extra.get(bone_name, Quaternion.IDENTITY) as Quaternion)

	var fk_rotations: Dictionary = data.get("fk_rotations", {})
	for bone_name in fk_rotations:
		var node: Node3D = rig_controller.find_node(bone_name)
		if node != null:
			node.quaternion = (fk_rotations[bone_name] as Quaternion) \
				* (fk_extra.get(bone_name, Quaternion.IDENTITY) as Quaternion)

	var root_pos: Variant = data.get("root_position", null)
	if root_pos != null:
		var rootdummy: Node3D = rig_controller.find_node("rootdummy")
		if rootdummy != null:
			rootdummy.global_position = root_pos

	return data

func _nearest_video_landmarks(t: float) -> Array:
	var best_idx := 0
	var best_dist := INF
	for i in _video_extracted_frames.size():
		var d: float = abs(_video_extracted_frames[i]["time"] - t)
		if d < best_dist:
			best_dist = d
			best_idx = i
	return _video_extracted_frames[best_idx]["world_landmarks"]

# Preview state for the video Lock&Bake flow: the previewed frame's params
# and computed pose are cached so Bake can measure the user's manual
# corrections against exactly what the preview put on screen.
var _video_previewed: bool = false
var _video_preview_params: Dictionary = {}
var _video_overlay_params: Dictionary = {}
var _video_preview_data: Dictionary = {}

## Applies the auto-computed pose of the frame nearest the timeline cursor
## onto the rig — the "precalcolata" starting point the user then adjusts by
## hand (gizmo, IK handles) before pressing Bake.
func _preview_video_frame() -> void:
	if _video_extracted_frames.is_empty():
		return
	# With a component still selected, _process copies the ACTIVE limb's pin
	# FROM the node instead of applying ours — the computed pose would be
	# silently overridden. Deselect so every pin we set actually lands.
	rig_controller.deselect()
	var p: Dictionary = await _compute_video_bake_params()
	var data: Dictionary = _apply_video_frame(_nearest_video_landmarks(side_panel.timeline.current_time), p)
	_video_overlay_params = p.duplicate(true)
	_video_preview_params = p
	_video_preview_data = data
	_video_previewed = not data.is_empty()
	_show_ai_landmark_overlay(_nearest_video_landmarks(side_panel.timeline.current_time))
	side_panel.set_status("Preview at %.2fs — adjust components by hand, then Bake." % side_panel.timeline.current_time)

## Measures the user's manual corrections on top of the previewed pose —
## dragged IK targets, rotated hands/feet, FK tweaks — as deltas that Bake
## then re-applies on EVERY frame. Same idea as the glb flow's Lock: pose
## one frame by hand, the bake maintains that exact offset.
func _capture_video_corrections() -> Dictionary:
	var extras := {"end": {}, "fk": {}, "target": {}}
	if _video_preview_data.is_empty():
		return extras
	var data: Dictionary = _video_preview_data
	var p: Dictionary = _video_preview_params

	for comp_id in data.get("ik_targets", {}):
		if not _limb_targets.has(comp_id):
			continue
		var auto_target: Vector3 = data["ik_targets"][comp_id]["target"]
		if comp_id == "right_leg" or comp_id == "left_leg":
			auto_target.y += p["foot_y"]
		var delta: Vector3 = _limb_targets[comp_id]["target"] - auto_target
		if delta.length() > 0.005:
			extras["target"][comp_id] = delta

	if p["use_end_bones"]:
		for bone_name in data.get("end_world_bases", {}):
			var node: Node3D = rig_controller.find_node(bone_name)
			if node == null:
				continue
			var auto_world: Basis = data["end_world_bases"][bone_name]
			var extra := Quaternion(auto_world.inverse() * node.global_basis)
			if extra.get_angle() > deg_to_rad(1.0):
				extras["end"][bone_name] = extra

	for bone_name in data.get("fk_rotations", {}):
		var node: Node3D = rig_controller.find_node(bone_name)
		if node == null:
			continue
		var extra: Quaternion = (data["fk_rotations"][bone_name] as Quaternion).inverse() * node.quaternion
		if extra.get_angle() > deg_to_rad(1.0):
			extras["fk"][bone_name] = extra

	return extras

func _on_video_apply_to_timeline() -> void:
	if _video_extracted_frames.is_empty():
		return

	# Lock&Bake: if the user previewed a frame (and possibly hand-adjusted
	# it), capture the corrections BEFORE anything resets the rig, and reuse
	# the preview's exact parameters so the deltas stay meaningful.
	var extras := {"end": {}, "fk": {}, "target": {}}
	var p: Dictionary
	if _video_previewed and not _video_preview_params.is_empty():
		extras = _capture_video_corrections()
		p = _video_preview_params
	else:
		p = await _compute_video_bake_params()

	_video_overlay_params = p.duplicate(true)
	# Deselect BEFORE the bake loop: _process copies the ACTIVE limb's pin
	# from the node every frame, which would override the per-frame pose we
	# set and silently discard the user's captured corrections.
	rig_controller.deselect()

	_push_undo_snapshot()

	# Resize the animation to match the video duration. _anim_length drives
	# playback wrap-around AND the exported MDL "length" — updating only the
	# UI here would silently export animations with the stale duration.
	_anim_length = _video_extracted_duration
	side_panel.set_duration(_anim_length)

	_on_play_toggled(false)
	var baked_keys: Array = []
	# Apply each frame as a keyframe
	for frame_data in _video_extracted_frames:
		_apply_video_frame(frame_data["world_landmarks"], p, extras)
		# Let the IK solver run for one frame before capturing
		await get_tree().process_frame
		var snapshot := MdlExporter.capture_pose($Rig)
		baked_keys.append({"time": frame_data["time"], "transforms": snapshot})

	if _video_panel.get_node("Scroll/Body/SimplifyPoses").button_pressed:
		baked_keys = preload("res://scripts/pose_reducer.gd").reduce_keys(baked_keys, int(_video_panel.get_node("Scroll/Body/KeyPoseRow/Count").value))
	side_panel.timeline.clear_selection()
	_keyframes = baked_keys
	_refresh_timeline_markers()

	_video_previewed = false
	_video_preview_params = {}
	_video_preview_data = {}

	# The panel stays open on purpose: baking is iterative (tweak calibration,
	# re-bake) and the overlay follows the panel's lifecycle — closing it is
	# how the user dismisses the whole debug context.
	var n_fix: int = extras["end"].size() + extras["fk"].size() + extras["target"].size()
	if n_fix > 0:
		side_panel.set_status("Baked %d keyframes with %d manual corrections (%.1fs)." % [_keyframes.size(), n_fix, _video_extracted_duration])
	else:
		side_panel.set_status("Baked %d keyframes from video (%.1fs)." % [_keyframes.size(), _video_extracted_duration])
	green_visualizer.visible = true
	_sync_video_pose_overlay(0.0)

func _save_retarget_config_to(path: String) -> void:
	var bone_map: Dictionary = side_panel.bone_config_panel.get_bone_map()
	var err := RetargetConfig.save_to_file(
		path,
		_retarget_config.get("prefab_name", path.get_file().get_basename()),
		_retarget_config.get("source_fps", 30.0),
		side_panel.bone_config_panel.get_root_scale(),
		bone_map
	)
	if err != OK:
		side_panel.set_status("Failed to save config (error %d)." % err)
		return
	_retarget_config["bone_map"] = bone_map
	side_panel.set_status("Config saved to %s" % path)
	side_panel.bone_config_panel.set_status("Config saved to %s" % path)

func _move_single_key(old_time: float, new_time: float) -> void:
	for key in _keyframes:
		if absf(key.time - new_time) < .001 and absf(key.time - old_time) > .001: return
	for key in _keyframes:
		if absf(key.time - old_time) < .001:
			key.time = new_time
			break
	_keyframes.sort_custom(func(a,b): return a.time < b.time)
	_refresh_timeline_markers()
	side_panel.timeline.set_current_time(new_time)
	_apply_pose_at_time(new_time)

func _update_nwn_skeleton() -> void:
	_nwn_skeleton_mesh.clear_surfaces()
	_nwn_skeleton_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for entry in MdlExporter.flatten_skeleton_tree():
		var node: Node3D = rig_controller.find_node(entry.name)
		if node == null: continue
		var p := _nwn_skeleton.to_local(node.global_position)
		var parent: Node3D = rig_controller.find_node(entry.parent) if entry.parent != "" else null
		if parent != null:
			_nwn_skeleton_mesh.surface_add_vertex(p)
			_nwn_skeleton_mesh.surface_add_vertex(_nwn_skeleton.to_local(parent.global_position))
		for axis in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
			_nwn_skeleton_mesh.surface_add_vertex(p - axis * .012)
			_nwn_skeleton_mesh.surface_add_vertex(p + axis * .012)
	_nwn_skeleton_mesh.surface_end()

func _nudge_selection(event: InputEventKey) -> bool:
	if get_viewport().gui_get_focus_owner() != null or event.is_command_or_control_pressed() or event.alt_pressed: return false
	if not _can_translate_selection(): return false
	var directions := {KEY_LEFT:Vector3.LEFT, KEY_RIGHT:Vector3.RIGHT, KEY_UP:Vector3.FORWARD, KEY_DOWN:Vector3.BACK, KEY_PAGEUP:Vector3.UP, KEY_PAGEDOWN:Vector3.DOWN}
	if not directions.has(event.keycode): return false
	if _playing: _on_play_toggled(false)
	var origin := _translation_anchor()
	if _active_ik_component != "": origin = _limb_targets[_active_ik_component]["target"]
	elif rig_controller.selected_components.size() == 1 and rig_controller.selected_component == "pelvis": origin = rig_controller.find_node("rootdummy").global_position
	_on_panel_position_changed(origin + directions[event.keycode] * .01)
	return true
