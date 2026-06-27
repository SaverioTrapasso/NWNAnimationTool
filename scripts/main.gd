extends Node3D

const DragHandleScript = preload("res://scripts/drag_handle.gd")
const TranslationGizmoScript = preload("res://scripts/translation_gizmo.gd")

@onready var rig_controller: Node3D = $RigController
@onready var gizmo: Node3D = $RotationGizmo
@onready var side_panel: Control = $SidePanel
@onready var blue_visualizer: Node3D = $BlueVisualizer
@onready var red_visualizer: Node3D = $RedVisualizer

# Per-limb world-space IK targets, kept even while that limb isn't the
# active selection so arms/legs keep tracking their last pose as the body
# (e.g. the pelvis height) moves underneath them.
var _limb_targets: Dictionary = {} # component_id -> {"target": Vector3, "pole": Vector3}

var _active_ik_component: String = ""
var _target_handle: Node3D = null
var _pole_handle: Node3D = null
var _root_height_handle: Node3D = null

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

# Clipboard for "Copy key" / "Paste key": lets you grab the pose at one point
# on the timeline and stamp it onto another keyframe, overwriting it.
var _copied_pose: Dictionary = {}

# Clipboard for "Copy sel." / "Paste sel.": the single currently-selected
# component's pose, independent of the timeline.
var _copied_component_pose: Dictionary = {}

func _ready() -> void:
	rig_controller.camera = $Camera3D
	rig_controller.rig_root = $Rig
	rig_controller.setup()
	rig_controller.component_selected.connect(_on_component_selected)
	rig_controller.component_deselected.connect(_on_component_deselected)

	gizmo.camera = $Camera3D
	side_panel.rig_root = $Rig
	side_panel.reset_pressed.connect(_on_reset_pressed)
	side_panel.pole_vectors_toggled.connect(_on_pole_vectors_toggled)
	side_panel.save_file_requested.connect(_on_save_file_requested)
	side_panel.open_file_requested.connect(_on_open_file_requested)
	side_panel.save_to_timeline_requested.connect(_on_save_to_timeline_requested)
	side_panel.duration_changed.connect(_on_duration_changed)
	side_panel.timeline.time_changed.connect(_on_timeline_scrubbed)
	side_panel.play_toggled.connect(_on_play_toggled)
	side_panel.copy_key_requested.connect(_on_copy_key_requested)
	side_panel.paste_key_requested.connect(_on_paste_key_requested)
	side_panel.remove_key_requested.connect(_on_remove_key_requested)
	side_panel.set_duration(_anim_length)
	side_panel.transform_panel.position_changed.connect(_on_panel_position_changed)
	side_panel.transform_panel.rotation_changed.connect(_on_panel_rotation_changed)
	side_panel.transform_panel.copy_selection_requested.connect(_on_copy_selection_requested)
	side_panel.transform_panel.paste_selection_requested.connect(_on_paste_selection_requested)
	side_panel.undo_requested.connect(_undo)
	side_panel.focus_requested.connect(_on_focus_pressed)
	gizmo.drag_started.connect(_push_undo_snapshot)

	side_panel.retarget_panel.load_animation_requested.connect(_on_retarget_load_animation_requested)
	side_panel.retarget_panel.bake_requested.connect(_on_retarget_bake_requested)
	side_panel.retarget_panel.bone_map_debug_requested.connect(_on_configure_rig_requested)
	side_panel.retarget_debug_panel.cfg_import_requested.connect(_on_retarget_cfg_import_requested)
	side_panel.retarget_debug_panel.apply_requested.connect(_on_retarget_apply_requested)
	side_panel.retarget_debug_panel.save_requested.connect(_on_retarget_save_config_requested)
	side_panel.retarget_debug_panel.save_as_chosen.connect(_on_retarget_save_as_chosen)
	side_panel.retarget_debug_panel.import_source_requested.connect(_on_compare_import_requested)
	side_panel.retarget_debug_panel.exit_requested.connect(_on_compare_exit_requested)
	side_panel.new_requested.connect(_on_new_requested)

	blue_visualizer.camera = $Camera3D
	red_visualizer.camera = $Camera3D
	blue_visualizer.bone_clicked.connect(_on_blue_bone_clicked)
	red_visualizer.bone_clicked.connect(_on_red_bone_clicked)

	_apply_component_materials($Rig)
	_capture_rest_transforms($Rig)
	_init_default_limb_targets()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_Z and event.is_command_or_control_pressed():
			_undo()
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

func _push_undo_snapshot() -> void:
	_undo_stack.append(MdlExporter.capture_pose($Rig))
	if _undo_stack.size() > UNDO_MAX_SIZE:
		_undo_stack.pop_front()

func _undo() -> void:
	if _undo_stack.is_empty():
		return
	var snapshot: Dictionary = _undo_stack.pop_back()
	_apply_transforms(snapshot)
	side_panel.set_status("Undo.")

func _capture_rest_transforms(node: Node) -> void:
	if node is Node3D:
		_rest_transforms[node] = node.transform
	for child in node.get_children():
		_capture_rest_transforms(child)

func _on_reset_pressed() -> void:
	_push_undo_snapshot()
	for node in _rest_transforms.keys():
		if is_instance_valid(node):
			node.transform = _rest_transforms[node]
	_init_default_limb_targets()
	var current_selection: String = rig_controller.selected_component
	if current_selection != "":
		_on_component_selected(current_selection)
	_refresh_all_pole_handles()

## "New": a harder reset than "Reset pose" — wipes the timeline, undo
## history, clipboards, retarget import state, and display toggles too,
## not just the pose. Confirmed via a dialog in side_panel.gd since it
## can't be undone (it clears the undo stack itself).
func _on_new_requested() -> void:
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

	_undo_stack.clear()
	_copied_pose = {}
	_copied_component_pose = {}

	_retarget_model_path = ""
	side_panel.retarget_panel.set_animation_label("No file loaded")
	if side_panel.retarget_panel.visible:
		side_panel.retarget_panel.toggle_visible()
	if side_panel.retarget_debug_panel.visible:
		side_panel.retarget_debug_panel.toggle_visible()
	if not _retarget_config_path.is_empty():
		_on_retarget_cfg_import_requested(_retarget_config_path) # reloads from disk, discarding unsaved edits

	side_panel.reset_display_toggles()
	side_panel.set_status("New project started.")

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
		elif node_to_component.has(node.name) and fk_component_ids.has(node_to_component[node.name]):
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

	for component_id in _limb_targets.keys():
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
	_refresh_transform_panel()
	_refresh_retarget_debug_panel()

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

func _on_component_selected(component_id: String) -> void:
	_clear_handles()
	var is_ik := false
	for comp in RigComponents.definitions():
		if comp.id == component_id:
			is_ik = comp.is_ik
			break
	if is_ik:
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
	_refresh_all_pole_handles()

	side_panel.transform_panel.visible = true
	side_panel.transform_panel.set_label(component_id)
	side_panel.transform_panel.set_position_enabled(is_ik or component_id == "pelvis")

func _on_component_deselected() -> void:
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

# ---------------------------------------------------------------------------
# Timeline / keyframes
# ---------------------------------------------------------------------------

func _on_duration_changed(value: float) -> void:
	_anim_length = value

func _on_save_to_timeline_requested() -> void:
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

func _on_save_file_requested(path: String, anim_name: String) -> void:
	var content: String
	if _keyframes.is_empty():
		content = MdlExporter.export_pose($Rig, anim_name)
	else:
		content = MdlExporter.export_animation($Rig, anim_name, _anim_length, _keyframes)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		side_panel.set_status("Error: could not write file.")
		return
	file.store_string(content)
	file.close()
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
	var panel: Panel = side_panel.transform_panel
	if not panel.visible or panel.any_field_focused():
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
			panel.set_rotation_fields(_basis_to_euler_degrees(node.basis))

func _on_panel_position_changed(v: Vector3) -> void:
	var component_id: String = rig_controller.selected_component
	if component_id == "pelvis":
		var root_dummy: Node3D = rig_controller.find_node("rootdummy")
		if root_dummy != null:
			root_dummy.global_position = v
		if _root_height_handle != null:
			_root_height_handle.global_position = v
	elif _active_ik_component != "":
		_limb_targets[_active_ik_component]["target"] = v
		if _target_handle != null:
			_target_handle.global_position = v

func _on_panel_rotation_changed(v: Vector3) -> void:
	var component_id: String = rig_controller.selected_component
	if component_id == "":
		return
	var is_ik := false
	for comp in RigComponents.definitions():
		if comp.id == component_id:
			is_ik = comp.is_ik
			break
	var basis := _euler_degrees_to_basis(v)
	if is_ik:
		var chain: Array[Node3D] = rig_controller.get_chain_nodes(component_id)
		if chain.size() == 3:
			chain[2].basis = basis
	else:
		var node: Node3D = rig_controller.get_component_root_node(component_id)
		if node != null:
			node.basis = basis

func _on_open_file_requested(path: String) -> void:
	_push_undo_snapshot()
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		side_panel.set_status("Error: could not read file.")
		return
	var text := file.get_as_text()
	file.close()

	var result = MdlImporter.parse(text, $Rig)
	if result == null:
		side_panel.set_status("Error: could not parse file (no 'newanim' found).")
		return

	_keyframes = result["keyframes"]
	_anim_length = result["length"]
	side_panel.set_anim_name(result["anim_name"])
	side_panel.set_duration(_anim_length)
	_refresh_timeline_markers()
	side_panel.timeline.set_current_time(0.0)
	_apply_pose_at_time(0.0)
	side_panel.set_status("Opened: %s" % path)

# ---------------------------------------------------------------------------
# Retargeting
# ---------------------------------------------------------------------------

var _retarget_config: Dictionary = {}
var _retarget_config_path: String = ""
var _retarget_model_path: String = ""

func _on_retarget_cfg_import_requested(config_path: String) -> void:
	_retarget_config_path = config_path
	_retarget_config = RetargetConfig.load_from_file(config_path)
	if _retarget_config.is_empty():
		side_panel.retarget_debug_panel.set_status("Couldn't load config: %s" % config_path)
	else:
		side_panel.retarget_debug_panel.set_status("Config '%s' loaded (%d bones mapped)." % [
			_retarget_config.get("prefab_name", "?"), _retarget_config.get("bone_map", {}).size()
		])
		side_panel.retarget_debug_panel.set_bone_map(
			RetargetConfig.NWN_NODES,
			_retarget_config.get("bone_map", {}),
			_retarget_config.get("rotation_offsets", {})
		)
		side_panel.retarget_debug_panel.set_root_scale(_retarget_config.get("root_scale", 1.0))

## "Carica animazione" in the Retarget panel: the model+animation file that
## Bake actually samples. Kept separate from "Import model" in Configure rig
## (which only drives the visual red-skeleton comparison) since you may want
## to bake a different file than the one used to build the bone map.
func _on_retarget_load_animation_requested(path: String) -> void:
	_retarget_model_path = path
	side_panel.retarget_panel.set_animation_label(path.get_file())
	side_panel.retarget_panel.set_status("Animation ready: %s" % path.get_file())

func _on_retarget_bake_requested() -> void:
	if _retarget_config.is_empty():
		side_panel.retarget_panel.set_status("Import a bone-map config first.")
		return
	if _retarget_model_path == "":
		side_panel.retarget_panel.set_status("Import a model file first.")
		return

	var rest_by_name: Dictionary = {}
	for node in _rest_transforms.keys():
		if is_instance_valid(node):
			rest_by_name[node.name] = _rest_transforms[node]

	# Read the bone map/offsets straight from the table, not from
	# _retarget_config, so edits made after import but not yet saved are
	# still honored by Bake (saving to disk is a separate, optional step).
	var result: Dictionary = Retargeter.bake(
		self,
		_retarget_model_path,
		side_panel.retarget_debug_panel.get_bone_map(),
		rest_by_name,
		_retarget_config["source_fps"],
		side_panel.retarget_debug_panel.get_root_scale(),
		side_panel.retarget_debug_panel.get_rotation_offsets()
	)

	if result.has("error"):
		side_panel.retarget_panel.set_status("Bake failed: %s" % result["error"])
		return

	_push_undo_snapshot()
	_keyframes = result["keyframes"]
	_anim_length = result["length"]
	side_panel.set_anim_name(result["anim_name"])
	side_panel.set_duration(_anim_length)
	_refresh_timeline_markers()
	side_panel.timeline.set_current_time(0.0)
	_apply_pose_at_time(0.0)
	side_panel.retarget_panel.set_status("Baked %d keyframes (%.2fs)." % [_keyframes.size(), _anim_length])

## Pulls whatever's currently in the bone-map panel's editable fields and
## writes it to a .cfg file (preserving the file's leading comment block).
## Always prompts for the filename/location (pre-filled with the currently
## loaded path, if any) instead of silently overwriting it — configs are
## meant to be shared/reused, so overwriting one without asking is risky.
func _on_retarget_save_config_requested() -> void:
	side_panel.retarget_debug_panel.prompt_save_as(_retarget_config_path)

func _on_retarget_save_as_chosen(path: String) -> void:
	_retarget_config_path = path
	_save_retarget_config_to(path)

func _save_retarget_config_to(path: String) -> void:
	var bone_map: Dictionary = side_panel.retarget_debug_panel.get_bone_map()
	var rotation_offsets: Dictionary = side_panel.retarget_debug_panel.get_rotation_offsets()
	var root_scale: float = side_panel.retarget_debug_panel.get_root_scale()
	var err := RetargetConfig.save_to_file(
		path,
		_retarget_config.get("prefab_name", path.get_file().get_basename()),
		_retarget_config.get("source_fps", 30.0),
		root_scale,
		bone_map,
		rotation_offsets
	)
	if err != OK:
		side_panel.retarget_panel.set_status("Failed to save config (error %d)." % err)
		return
	_retarget_config["bone_map"] = bone_map
	_retarget_config["rotation_offsets"] = rotation_offsets
	_retarget_config["root_scale"] = root_scale
	side_panel.retarget_panel.set_status("Config saved to %s" % path)
	side_panel.retarget_debug_panel.set_status("Config saved to %s" % path)

# ---------------------------------------------------------------------------
# Visual rig compare/configure mode: click a joint on the blue NWN dummy and
# the matching one on the red imported skeleton to build the bone map,
# instead of typing names blind.
# ---------------------------------------------------------------------------

var _compare_mode: bool = false
var _pending_blue_bone: String = ""
var _pending_red_bone: String = ""
var _compare_red_scene: Node3D = null

const COMPARE_BLUE_TINT := Color(0.2, 0.45, 0.95)
const COMPARE_RED_TINT := Color(0.9, 0.2, 0.2)

## Single entry point for "Configure rig": shows the editable bone-map
## table AND sets up the visual aid (NWN mesh tinted blue, with clickable
## joint dots) in one go. Clicking Import inside that panel adds the red
## comparison skeleton; clicking pairs of joints fills in the table.
func _on_configure_rig_requested() -> void:
	_compare_mode = true
	rig_controller.deselect()
	_clear_handles()
	gizmo.detach()
	rig_controller.set_process_unhandled_input(false)
	side_panel.retarget_panel.visible = false
	side_panel.transform_panel.visible = false
	_pending_blue_bone = ""
	_pending_red_bone = ""

	# Real NWN mesh tinted blue (the silhouette itself is the reference),
	# with small clickable dots at each joint but no stick-figure lines —
	# the mesh already shows how everything connects.
	_tint_meshes($Rig, COMPARE_BLUE_TINT)
	_build_blue_visualizer()
	blue_visualizer.visible = true

	side_panel.retarget_debug_panel.set_bone_map(
		RetargetConfig.NWN_NODES,
		_retarget_config.get("bone_map", {}),
		_retarget_config.get("rotation_offsets", {})
	)
	side_panel.retarget_debug_panel.show_panel()
	side_panel.retarget_debug_panel.set_status("Edit the table, or click Import to compare visually.")

func _build_blue_visualizer() -> void:
	var flat: Array = MdlExporter.flatten_skeleton_tree()
	var entries: Array = []
	for entry in flat:
		var node: Node3D = rig_controller.find_node(entry["name"])
		if node == null:
			continue
		var parent_pos: Variant = null
		if entry["parent"] != "":
			var pnode: Node3D = rig_controller.find_node(entry["parent"])
			if pnode != null:
				parent_pos = pnode.global_position
		entries.append({"name": entry["name"], "position": node.global_position, "parent_position": parent_pos})
	blue_visualizer.build(entries, false)

## Recursively tints every MeshInstance3D under node a flat color — used to
## turn the real NWN mesh (or an imported source mesh, if it has one) into a
## clear color-coded silhouette for the rig-compare view.
func _tint_meshes(node: Node, color: Color) -> void:
	if node is MeshInstance3D:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.roughness = 0.85
		node.material_override = mat
	for child in node.get_children():
		_tint_meshes(child, color)

func _on_compare_import_requested(path: String) -> void:
	var scene: Node3D = Retargeter._load_glb(path)
	if scene == null:
		side_panel.retarget_debug_panel.set_status("Could not load file.")
		return
	var skeleton: Skeleton3D = Retargeter._find_skeleton(scene)
	if skeleton == null:
		scene.queue_free()
		side_panel.retarget_debug_panel.set_status("No Skeleton3D found in that file.")
		return

	_retarget_model_path = path

	if _compare_red_scene != null:
		_compare_red_scene.queue_free()
	add_child(scene)
	_compare_red_scene = scene
	_tint_meshes(scene, COMPARE_RED_TINT) # no-op if the source has no mesh (most skeleton-only exports)

	# Pose at the animation's frame 0 (not the bind/rest pose) — calibrating
	# the bone map only makes sense against the actual first frame of the
	# file you're about to bake, same as what Bake itself starts from.
	var anim_player := Retargeter._find_animation_player(scene)
	if anim_player != null:
		var anim_names := anim_player.get_animation_list()
		if not anim_names.is_empty():
			anim_player.play(anim_names[0])
			anim_player.seek(0.0, true)
			anim_player.pause()

	_refresh_red_visualizer(skeleton)

	var bone_names: Array = []
	for i in range(skeleton.get_bone_count()):
		bone_names.append(skeleton.get_bone_name(i))
	side_panel.retarget_debug_panel.set_available_bones(bone_names)
	side_panel.retarget_debug_panel.set_status("Loaded %s (%d bones). Click pairs of joints, or pick from the dropdowns." % [path.get_file(), skeleton.get_bone_count()])

## Rebuilds the red stick-figure from the source skeleton's CURRENT bone
## poses (rest pose by default; _on_retarget_apply_requested temporarily
## poses it with the rotation offsets first so they can be checked visually).
func _refresh_red_visualizer(skeleton: Skeleton3D) -> void:
	var entries: Array = []
	for i in range(skeleton.get_bone_count()):
		var bone_name: String = skeleton.get_bone_name(i)
		var pos: Vector3 = skeleton.global_transform * skeleton.get_bone_global_pose(i).origin
		var parent_idx: int = skeleton.get_bone_parent(i)
		var parent_pos: Variant = null
		if parent_idx >= 0:
			parent_pos = skeleton.global_transform * skeleton.get_bone_global_pose(parent_idx).origin
		entries.append({"name": bone_name, "position": pos, "parent_position": parent_pos})
	red_visualizer.build(entries) # draw_lines=true: usually the only way to see a mesh-less skeleton
	red_visualizer.visible = true

## "Applica" button: poses the imported source skeleton's mapped bones with
## the rotation offsets currently typed into the table, and scales the whole
## preview by the current root scale, so the red skeleton visually reflects
## both tweaks instead of only showing its rest pose at scale 1.
func _on_retarget_apply_requested() -> void:
	if _compare_red_scene == null:
		side_panel.retarget_debug_panel.set_status("Import a model first.")
		return
	var skeleton: Skeleton3D = Retargeter._find_skeleton(_compare_red_scene)
	if skeleton == null:
		return
	_compare_red_scene.scale = Vector3.ONE * side_panel.retarget_debug_panel.get_root_scale()
	var bone_map: Dictionary = side_panel.retarget_debug_panel.get_bone_map()
	var rotation_offsets: Dictionary = side_panel.retarget_debug_panel.get_rotation_offsets()
	for nwn_node in bone_map.keys():
		var source_bone: String = bone_map[nwn_node]
		if source_bone == "":
			continue
		var idx := skeleton.find_bone(source_bone)
		if idx == -1:
			continue
		var rest_rot: Quaternion = skeleton.get_bone_rest(idx).basis.get_rotation_quaternion()
		var offset_deg: Vector3 = rotation_offsets.get(nwn_node, Vector3.ZERO)
		var offset_quat := Quaternion.from_euler(Vector3(
			deg_to_rad(offset_deg.x), deg_to_rad(offset_deg.y), deg_to_rad(offset_deg.z)
		))
		skeleton.set_bone_pose_rotation(idx, rest_rot * offset_quat)
	_refresh_red_visualizer(skeleton)
	side_panel.retarget_debug_panel.set_status("Applied offsets to the preview skeleton.")

func _on_blue_bone_clicked(bone_name: String) -> void:
	if not _compare_mode:
		return
	_pending_blue_bone = bone_name
	blue_visualizer.set_highlight(bone_name)
	_try_complete_compare_pair()

func _on_red_bone_clicked(bone_name: String) -> void:
	if not _compare_mode:
		return
	_pending_red_bone = bone_name
	red_visualizer.set_highlight(bone_name)
	_try_complete_compare_pair()

func _try_complete_compare_pair() -> void:
	if _pending_blue_bone == "" or _pending_red_bone == "":
		return
	side_panel.retarget_debug_panel.set_ff14_value(_pending_blue_bone, _pending_red_bone)
	side_panel.retarget_debug_panel.set_status("%s → %s. Click more, or Save config in the table." % [_pending_blue_bone, _pending_red_bone])
	blue_visualizer.set_highlight("")
	red_visualizer.set_highlight("")
	_pending_blue_bone = ""
	_pending_red_bone = ""

func _on_compare_exit_requested() -> void:
	_compare_mode = false
	blue_visualizer.clear()
	blue_visualizer.visible = false
	red_visualizer.clear()
	red_visualizer.visible = false
	if _compare_red_scene != null:
		_compare_red_scene.queue_free()
		_compare_red_scene = null
	_apply_component_materials($Rig) # restore the normal IK/FK color scheme
	rig_controller.set_process_unhandled_input(true)
	side_panel.retarget_debug_panel.hide_panel()
	side_panel.retarget_panel.visible = true

## Live "delta from rest" readout per mapped NWN node, for the bone-map
## debug window — a bone stuck at ~0 means it isn't actually being driven
## (bad name / not found in the source); a wild value usually means the
## source and NWN bone axes don't line up the way the retarget math assumes.
func _refresh_retarget_debug_panel() -> void:
	if not side_panel.retarget_debug_panel.visible or _retarget_config.is_empty():
		return
	var bone_map: Dictionary = _retarget_config.get("bone_map", {})
	for nwn_node_name in bone_map.keys():
		var node: Node3D = rig_controller.find_node(nwn_node_name)
		var rest_transform: Variant = null
		for rest_node in _rest_transforms.keys():
			if is_instance_valid(rest_node) and rest_node.name == nwn_node_name:
				rest_transform = _rest_transforms[rest_node]
				break
		if node == null or rest_transform == null:
			side_panel.retarget_debug_panel.set_delta(nwn_node_name, INF)
			continue
		var rest_rot: Quaternion = rest_transform.basis.get_rotation_quaternion()
		var current_rot: Quaternion = node.basis.get_rotation_quaternion()
		var delta_angle: float = rad_to_deg((rest_rot.inverse() * current_rot).get_angle())
		side_panel.retarget_debug_panel.set_delta(nwn_node_name, delta_angle)
