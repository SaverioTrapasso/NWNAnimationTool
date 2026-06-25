extends Node3D

## A small draggable sphere handle used for IK targets and pole vectors.
## Drags on a plane facing the camera that passes through the handle's
## current position, so it tracks mouse movement in screen space.

signal moved(new_position: Vector3)
signal drag_started()

const PICK_LAYER := 4
const RADIUS := 0.035

@export var color: Color = Color.YELLOW
## If non-zero, dragging is constrained to move only along this world-space axis.
@export var constraint_axis: Vector3 = Vector3.ZERO
var camera: Camera3D = null

var _body: StaticBody3D
var _dragging: bool = false
var _drag_start_pos: Vector3

func _ready() -> void:
	var mesh := SphereMesh.new()
	mesh.radius = RADIUS
	mesh.height = RADIUS * 2.0
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.no_depth_test = true
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	add_child(mi)

	_body = StaticBody3D.new()
	_body.collision_layer = PICK_LAYER
	_body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var sphere_shape := SphereShape3D.new()
	sphere_shape.radius = RADIUS * 1.8
	shape.shape = sphere_shape
	_body.add_child(shape)
	add_child(_body)
	_body.set_meta("handle", self)

func _unhandled_input(event: InputEvent) -> void:
	if camera == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if _ray_hits_self(event.position):
				_dragging = true
				_drag_start_pos = global_position
				drag_started.emit()
				get_viewport().set_input_as_handled()
		else:
			_dragging = false
	elif event is InputEventMouseMotion and _dragging:
		var plane := Plane(-camera.global_transform.basis.z, global_position)
		var ray_origin := camera.project_ray_origin(event.position)
		var ray_dir := camera.project_ray_normal(event.position)
		var hit: Variant = plane.intersects_ray(ray_origin, ray_dir)
		if hit != null:
			if constraint_axis != Vector3.ZERO:
				var axis := constraint_axis.normalized()
				var t: float = (hit - _drag_start_pos).dot(axis)
				global_position = _drag_start_pos + axis * t
			else:
				global_position = hit
			moved.emit(global_position)
		get_viewport().set_input_as_handled()

func _ray_hits_self(screen_pos: Vector2) -> bool:
	var space_state := camera.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		camera.project_ray_origin(screen_pos),
		camera.project_ray_origin(screen_pos) + camera.project_ray_normal(screen_pos) * 100.0
	)
	query.collision_mask = PICK_LAYER
	var result := space_state.intersect_ray(query)
	return not result.is_empty() and result.collider == _body
