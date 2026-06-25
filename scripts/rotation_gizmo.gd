extends Node3D

## A 3-axis rotation gizmo (X/Y/Z rings). Click-drag a ring to rotate the
## current target node around that axis, in the target's local/parent space
## (matching how NWN orientationkeys are stored as parent-relative rotations).

const RADIUS := 0.18
const RING_SEGMENTS := 48
const PICK_TOLERANCE := 0.035

var target: Node3D = null
var camera: Camera3D = null

var _axis_meshes: Dictionary = {} # "x"/"y"/"z" -> MeshInstance3D
var _dragging_axis: String = ""
var _drag_start_mouse_angle: float = 0.0
var _drag_start_basis: Basis

func _ready() -> void:
	_axis_meshes["x"] = _make_ring(Color(1, 0.2, 0.2), Vector3.RIGHT)
	_axis_meshes["y"] = _make_ring(Color(0.2, 1, 0.2), Vector3.UP)
	_axis_meshes["z"] = _make_ring(Color(0.2, 0.4, 1), Vector3.FORWARD)
	visible = false

func _make_ring(color: Color, normal: Vector3) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINE_STRIP)
	for i in range(RING_SEGMENTS + 1):
		var angle := TAU * i / RING_SEGMENTS
		var p := Vector3(cos(angle), 0, sin(angle)) * RADIUS
		if normal == Vector3.RIGHT:
			p = Vector3(0, p.x, p.z)
		elif normal == Vector3.FORWARD:
			p = Vector3(p.x, p.z, 0)
		st.set_color(color)
		st.add_vertex(p)
	var mesh := st.commit()

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.no_depth_test = true
	mat.render_priority = 10

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.set_meta("axis", _normal_to_axis_name(normal))
	add_child(mi)
	return mi

func _normal_to_axis_name(normal: Vector3) -> String:
	if normal == Vector3.RIGHT:
		return "x"
	if normal == Vector3.UP:
		return "y"
	return "z"

func attach_to(node: Node3D) -> void:
	target = node
	visible = target != null
	if target != null:
		global_position = target.global_position
		global_basis = target.global_basis

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
				_drag_start_mouse_angle = _mouse_angle_on_axis_plane(axis, event.position)
				_drag_start_basis = target.basis
				get_viewport().set_input_as_handled()
		else:
			_dragging_axis = ""
	elif event is InputEventMouseMotion and _dragging_axis != "":
		var current_angle := _mouse_angle_on_axis_plane(_dragging_axis, event.position)
		var delta_angle := current_angle - _drag_start_mouse_angle
		var local_axis := Vector3.RIGHT
		if _dragging_axis == "y":
			local_axis = Vector3.UP
		elif _dragging_axis == "z":
			local_axis = Vector3.FORWARD
		target.basis = _drag_start_basis * Basis(local_axis, delta_angle)
		get_viewport().set_input_as_handled()

## Ray-plane intersection test against each ring's plane, returns the closest
## axis whose intersection point lies within PICK_TOLERANCE of the ring radius.
func _pick_axis(screen_pos: Vector2) -> String:
	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_dir := camera.project_ray_normal(screen_pos)
	var best_axis := ""
	var best_dist := INF
	for axis_name in ["x", "y", "z"]:
		var local_normal := Vector3.RIGHT if axis_name == "x" else (Vector3.UP if axis_name == "y" else Vector3.FORWARD)
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
	var local_normal := Vector3.RIGHT if axis_name == "x" else (Vector3.UP if axis_name == "y" else Vector3.FORWARD)
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
