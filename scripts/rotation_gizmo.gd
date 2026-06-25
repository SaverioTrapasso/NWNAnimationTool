extends Node3D

## A 3-axis rotation gizmo (X/Y/Z rings). Click-drag a ring to rotate the
## current target node around that axis, in the target's local/parent space
## (matching how NWN orientationkeys are stored as parent-relative rotations).

signal drag_started()

## Kept clearly outside TranslationGizmo's arrow reach (~0.13 with current
## constants), so there's a real gap between the move arrows and the
## rotation rings — no more misclicking one for the other.
const RADIUS := 0.2
const TUBE_THICKNESS := 0.014
const RING_SEGMENTS := 48
const TUBE_SEGMENTS := 32
const PICK_TOLERANCE := 0.03

var target: Node3D = null
var camera: Camera3D = null

# All ring meshes live under this node instead of directly under self. self's
# own global_basis is the frozen reference frame used for angle measurement
# while dragging (see _process); _visual_root is spun live by the drag delta
# purely for visual feedback, without disturbing that measurement frame.
var _visual_root: Node3D

var _dragging_axis: String = ""
var _dragging_local_axis: Vector3 = Vector3.UP
var _drag_start_mouse_angle: float = 0.0
var _drag_start_basis: Basis

func _ready() -> void:
	_visual_root = Node3D.new()
	add_child(_visual_root)
	_make_ring(Color(1, 0.2, 0.2), Vector3.RIGHT, Vector3(0, 0, 90), 12)
	_make_ring(Color(0.2, 1, 0.2), Vector3.UP, Vector3(0, 0, 0), 11)
	_make_ring(Color(0.2, 0.4, 1), Vector3.BACK, Vector3(90, 0, 0), 10)
	visible = false

func _make_ring(color: Color, _normal: Vector3, rotation_deg: Vector3, priority: int) -> void:
	var torus := TorusMesh.new()
	torus.inner_radius = RADIUS - TUBE_THICKNESS * 0.5
	torus.outer_radius = RADIUS + TUBE_THICKNESS * 0.5
	torus.rings = TUBE_SEGMENTS
	torus.ring_segments = RING_SEGMENTS

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	# no_depth_test keeps the rings visible through the body mesh, but with
	# depth testing off the GPU has no stable order between the three rings
	# where they cross each other — giving them distinct render priorities
	# fixes that flicker (the renderer falls back to priority instead of depth).
	mat.no_depth_test = true
	mat.render_priority = priority

	var mi := MeshInstance3D.new()
	mi.mesh = torus
	mi.material_override = mat
	mi.rotation_degrees = rotation_deg
	_visual_root.add_child(mi)

func attach_to(node: Node3D) -> void:
	target = node
	visible = target != null
	if target != null:
		global_position = target.global_position
		global_basis = target.global_basis
		_visual_root.basis = Basis()

func detach() -> void:
	target = null
	_dragging_axis = ""
	visible = false

func _process(_delta: float) -> void:
	if target == null or not is_instance_valid(target):
		return
	global_position = target.global_position
	# While actively dragging a ring, freeze the gizmo's own orientation:
	# it doubles as the reference frame for measuring the drag angle, so
	# letting it rotate live with the target would chase its own tail
	# (the more it rotates, the smaller the measured angle gets). Once the
	# drag ends it snaps back in sync with the target's new orientation.
	if _dragging_axis == "":
		global_basis = target.global_basis

func _unhandled_input(event: InputEvent) -> void:
	if target == null or camera == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var axis := _pick_axis(event.position)
			if axis != "":
				_dragging_axis = axis
				_dragging_local_axis = Vector3.RIGHT if axis == "x" else (Vector3.UP if axis == "y" else Vector3.BACK)
				_drag_start_mouse_angle = _mouse_angle_on_axis_plane(axis, event.position)
				_drag_start_basis = target.basis
				_visual_root.basis = Basis()
				drag_started.emit()
				get_viewport().set_input_as_handled()
		else:
			_dragging_axis = ""
			_visual_root.basis = Basis()
	elif event is InputEventMouseMotion and _dragging_axis != "":
		var current_angle := _mouse_angle_on_axis_plane(_dragging_axis, event.position)
		var delta_angle := current_angle - _drag_start_mouse_angle
		target.basis = _drag_start_basis * Basis(_dragging_local_axis, delta_angle)
		# Spin the rings live by the same delta for immediate visual feedback;
		# self.global_basis (the measurement frame above) stays untouched.
		_visual_root.basis = Basis(_dragging_local_axis, delta_angle)
		get_viewport().set_input_as_handled()

## Ray-plane intersection test against each ring's plane, returns the closest
## axis whose intersection point lies within PICK_TOLERANCE of the ring radius.
func _pick_axis(screen_pos: Vector2) -> String:
	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_dir := camera.project_ray_normal(screen_pos)
	var best_axis := ""
	var best_dist := INF
	for axis_name in ["x", "y", "z"]:
		var local_normal := Vector3.RIGHT if axis_name == "x" else (Vector3.UP if axis_name == "y" else Vector3.BACK)
		var world_normal := global_basis * local_normal
		var plane := Plane(world_normal, global_position)
		var hit: Variant = plane.intersects_ray(ray_origin, ray_dir)
		if hit == null:
			continue
		var dist_from_center: float = (hit - global_position).length()
		var ring_error: float = abs(dist_from_center - RADIUS)
		if ring_error < PICK_TOLERANCE and ring_error < best_dist:
			best_dist = ring_error
			best_axis = axis_name
	return best_axis

func _mouse_angle_on_axis_plane(axis_name: String, screen_pos: Vector2) -> float:
	var local_normal := Vector3.RIGHT if axis_name == "x" else (Vector3.UP if axis_name == "y" else Vector3.BACK)
	var world_normal := global_basis * local_normal
	var plane := Plane(world_normal, global_position)
	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_dir := camera.project_ray_normal(screen_pos)
	var hit: Variant = plane.intersects_ray(ray_origin, ray_dir)
	if hit == null:
		return 0.0
	var local_point: Vector3 = global_basis.inverse() * (hit - global_position)
	if axis_name == "x":
		return atan2(local_point.z, local_point.y)
	elif axis_name == "y":
		return atan2(local_point.x, local_point.z)
	else:
		return atan2(local_point.y, local_point.x)
