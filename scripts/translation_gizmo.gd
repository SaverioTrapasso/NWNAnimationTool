extends Node3D

## A 3-axis translation gizmo: drag the red/green/blue arrow to move along
## only that world axis (precise IK target/pole positioning), or drag the
## small center dot to move freely in the camera-facing plane like before.
## Emits "moved" with the same signature as drag_handle.gd, so it's a
## drop-in replacement wherever a DragHandle is used.

signal moved(new_position: Vector3)
signal drag_started()

## Kept short and well inside RotationGizmo.RADIUS (with a clear gap) so the
## move arrows and the rotation rings never overlap and can't be misclicked
## for one another.
const ARROW_LENGTH := 0.1
const ARROW_RADIUS := 0.008
const HEAD_LENGTH := 0.032
const HEAD_RADIUS := 0.018
const CENTER_RADIUS := 0.016
const PICK_TOLERANCE := 0.016

@export var color: Color = Color.YELLOW
var camera: Camera3D = null

var _dragging_mode: String = "" # "", "x", "y", "z", "free"
var _drag_start_pos: Vector3
## Where the click ray actually hit the drag plane at press time — usually
## NOT the same point as _drag_start_pos, since you click somewhere along
## the arrow's shaft/head, not exactly on its pivot. Motion is measured
## relative to this point so the cursor-to-gizmo offset stays constant
## through the drag instead of the gizmo snapping to track the cursor.
var _drag_start_hit: Vector3

func _ready() -> void:
	# Must see clicks before RigController's own selection raycast does —
	# otherwise a click on the arrow tip (outside the body mesh's pick
	# collider) makes RigController's ray miss and deselect/reselect before
	# the gizmo gets a chance to claim the same click, snapping the pose for
	# a frame as the IK re-pins to its last remembered orientation.
	process_priority = -10
	_make_arrow(Color(1, 0.2, 0.2), Vector3.RIGHT, Vector3(0, 0, -90))
	_make_arrow(Color(0.2, 1, 0.2), Vector3.UP, Vector3(0, 0, 0))
	_make_arrow(Color(0.2, 0.4, 1), Vector3.FORWARD, Vector3(-90, 0, 0))
	_make_center()

func _make_arrow(arrow_color: Color, _axis: Vector3, rotation_deg: Vector3) -> void:
	var holder := Node3D.new()
	holder.rotation_degrees = rotation_deg
	add_child(holder)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = arrow_color
	mat.no_depth_test = true
	mat.render_priority = 10

	var shaft_mesh := CylinderMesh.new()
	shaft_mesh.top_radius = ARROW_RADIUS
	shaft_mesh.bottom_radius = ARROW_RADIUS
	shaft_mesh.height = ARROW_LENGTH
	var shaft := MeshInstance3D.new()
	shaft.mesh = shaft_mesh
	shaft.material_override = mat
	shaft.position = Vector3(0, ARROW_LENGTH * 0.5, 0)
	holder.add_child(shaft)

	var head_mesh := CylinderMesh.new()
	head_mesh.top_radius = 0.0
	head_mesh.bottom_radius = HEAD_RADIUS
	head_mesh.height = HEAD_LENGTH
	var head := MeshInstance3D.new()
	head.mesh = head_mesh
	head.material_override = mat
	head.position = Vector3(0, ARROW_LENGTH + HEAD_LENGTH * 0.5, 0)
	holder.add_child(head)

func _make_center() -> void:
	var mesh := SphereMesh.new()
	mesh.radius = CENTER_RADIUS
	mesh.height = CENTER_RADIUS * 2.0
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.no_depth_test = true
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	add_child(mi)

func _unhandled_input(event: InputEvent) -> void:
	if camera == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var mode := _pick_mode(event.position)
			if mode != "":
				_dragging_mode = mode
				drag_started.emit()
				_drag_start_pos = global_position
				var ray_origin := camera.project_ray_origin(event.position)
				var ray_dir := camera.project_ray_normal(event.position)
				var plane := Plane(-camera.global_transform.basis.z, _drag_start_pos)
				var hit: Variant = plane.intersects_ray(ray_origin, ray_dir)
				_drag_start_hit = hit if hit != null else _drag_start_pos
				get_viewport().set_input_as_handled()
		else:
			_dragging_mode = ""
	elif event is InputEventMouseMotion and _dragging_mode != "":
		var ray_origin := camera.project_ray_origin(event.position)
		var ray_dir := camera.project_ray_normal(event.position)
		var plane := Plane(-camera.global_transform.basis.z, _drag_start_pos)
		var hit: Variant = plane.intersects_ray(ray_origin, ray_dir)
		if hit != null:
			var moved_by: Vector3 = hit - _drag_start_hit
			if _dragging_mode == "free":
				global_position = _drag_start_pos + moved_by
			else:
				var axis := Vector3.RIGHT if _dragging_mode == "x" else (Vector3.UP if _dragging_mode == "y" else Vector3.FORWARD)
				var t: float = moved_by.dot(axis)
				global_position = _drag_start_pos + axis * t
			moved.emit(global_position)
		get_viewport().set_input_as_handled()

## Returns "x"/"y"/"z" if an arrow was clicked, "free" if the center dot
## was clicked, or "" if nothing on the gizmo was hit.
func _pick_mode(screen_pos: Vector2) -> String:
	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_dir := camera.project_ray_normal(screen_pos)

	# Center dot: simple point-to-ray distance.
	var to_center := global_position - ray_origin
	var center_t: float = to_center.dot(ray_dir)
	var center_closest := ray_origin + ray_dir * center_t
	if (center_closest - global_position).length() < CENTER_RADIUS + PICK_TOLERANCE:
		return "free"

	var best_mode := ""
	var best_dist := INF
	for mode in ["x", "y", "z"]:
		var axis := Vector3.RIGHT if mode == "x" else (Vector3.UP if mode == "y" else Vector3.FORWARD)
		var seg_end := global_position + axis * (ARROW_LENGTH + HEAD_LENGTH)
		var dist := _ray_to_segment_distance(ray_origin, ray_dir, global_position, seg_end)
		if dist < PICK_TOLERANCE and dist < best_dist:
			best_dist = dist
			best_mode = mode
	return best_mode

## Closest distance between an infinite ray (origin + t*dir, t>=0) and a
## finite segment (a..b). Standard closest-point-between-two-lines solve,
## clamped to the ray's and segment's valid ranges.
func _ray_to_segment_distance(ray_origin: Vector3, ray_dir: Vector3, seg_a: Vector3, seg_b: Vector3) -> float:
	var seg_dir := seg_b - seg_a
	var seg_len := seg_dir.length()
	if seg_len < 0.0001:
		return (seg_a - ray_origin).cross(ray_dir).length()
	seg_dir /= seg_len

	var r := ray_origin - seg_a
	var b := ray_dir.dot(seg_dir)
	var d := ray_dir.dot(r)
	var e := seg_dir.dot(r)
	var denom := 1.0 - b * b

	var t: float
	var s: float
	if abs(denom) > 0.0001:
		t = (b * e - d) / denom
		s = (e - b * d) / denom
	else:
		t = 0.0
		s = e

	t = max(t, 0.0)
	s = clamp(s, 0.0, seg_len)
	var closest_ray := ray_origin + ray_dir * t
	var closest_seg := seg_a + seg_dir * s
	return (closest_ray - closest_seg).length()
