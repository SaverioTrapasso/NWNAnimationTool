extends Node3D

const DragHandleScript = preload("res://scripts/drag_handle.gd")
const TranslationGizmoScript = preload("res://scripts/translation_gizmo.gd")

@onready var rig_controller: Node3D = $RigController
@onready var gizmo: Node3D = $RotationGizmo
@onready var side_panel: Control = $SidePanel

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
	side_panel.undo_requested.connect(_undo)
	side_panel.focus_requested.connect(_on_focus_pressed)
	gizmo.drag_started.connect(_push_undo_snapshot)

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
