extends Node3D

const DragHandleScript = preload("res://scripts/drag_handle.gd")

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

	_apply_component_materials($Rig)
	_capture_rest_transforms($Rig)
	_init_default_limb_targets()

func _capture_rest_transforms(node: Node) -> void:
	if node is Node3D:
		_rest_transforms[node] = node.transform
	for child in node.get_children():
		_capture_rest_transforms(child)

func _on_reset_pressed() -> void:
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
		_all_pole_handles[component_id].queue_free()
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

func _process(_delta: float) -> void:
	for component_id in _limb_targets.keys():
		var chain: Array[Node3D] = rig_controller.get_chain_nodes(component_id)
		if chain.size() != 3:
			continue
		var t: Dictionary = _limb_targets[component_id]
		IKSolver.solve_two_bone(chain[0], chain[1], chain[2], t["target"], t["pole"])

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

func _on_component_deselected() -> void:
	gizmo.detach()
	_clear_handles()
	_refresh_all_pole_handles()

func _setup_ik_handles(component_id: String) -> void:
	_active_ik_component = component_id
	if not _limb_targets.has(component_id):
		return
	var t: Dictionary = _limb_targets[component_id]

	_target_handle = DragHandleScript.new()
	_target_handle.color = Color(1.0, 0.85, 0.1)
	add_child(_target_handle)
	_target_handle.camera = $Camera3D
	_target_handle.global_position = t["target"]
	_target_handle.moved.connect(_on_target_moved)

	_pole_handle = DragHandleScript.new()
	_pole_handle.color = Color(0.2, 0.9, 1.0)
	add_child(_pole_handle)
	_pole_handle.camera = $Camera3D
	_pole_handle.global_position = t["pole"]
	_pole_handle.moved.connect(_on_pole_moved)

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
	_root_height_handle = DragHandleScript.new()
	_root_height_handle.color = Color(0.6, 1.0, 0.4)
	add_child(_root_height_handle)
	_root_height_handle.camera = $Camera3D
	_root_height_handle.global_position = root_dummy.global_position
	_root_height_handle.moved.connect(_on_root_height_moved)

func _on_root_height_moved(pos: Vector3) -> void:
	var root_dummy: Node3D = rig_controller.find_node("rootdummy")
	if root_dummy != null:
		root_dummy.global_position = pos

func _clear_handles() -> void:
	_active_ik_component = ""
	if _target_handle != null:
		_target_handle.queue_free()
		_target_handle = null
	if _pole_handle != null:
		_pole_handle.queue_free()
		_pole_handle = null
	if _root_height_handle != null:
		_root_height_handle.queue_free()
		_root_height_handle = null
