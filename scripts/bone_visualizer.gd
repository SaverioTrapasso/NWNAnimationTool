extends Node3D

## Draws a colored joint/bone skeleton overlay (sphere per joint, line to its
## parent) and lets the user click a joint to pick it — used by the visual
## rig-compare/configure view to build a bone mapping by clicking instead of
## typing names. Works for either side (NWN "blue" or imported-source "red")
## since it only needs a flat list of named world positions + parent links.

signal bone_clicked(bone_name: String)

const PICK_LAYER := 16
const SPHERE_RADIUS := 0.02
const PICK_RADIUS := 0.045
const LINE_RADIUS := 0.006

@export var color: Color = Color.RED
var camera: Camera3D = null

var _bodies: Dictionary = {} # StaticBody3D -> bone_name
var _joint_materials: Dictionary = {} # bone_name -> StandardMaterial3D
var _highlighted: String = ""

## entries: Array of {"name": String, "position": Vector3 (world),
## "parent_position": Vector3 or null}. Set draw_lines=false when the real
## mesh already shows the silhouette (e.g. the NWN dummy) and only the
## clickable joint dots are needed.
func build(entries: Array, draw_lines: bool = true) -> void:
	clear()
	for entry in entries:
		_add_joint(entry["name"], entry["position"])
		if draw_lines and entry.get("parent_position") != null:
			_add_bone_line(entry["position"], entry["parent_position"])

func clear() -> void:
	for child in get_children():
		child.queue_free()
	_bodies.clear()
	_joint_materials.clear()
	_highlighted = ""

func _add_joint(bone_name: String, pos: Vector3) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = SPHERE_RADIUS
	mesh.height = SPHERE_RADIUS * 2.0
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.no_depth_test = true
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	add_child(mi)
	_joint_materials[bone_name] = mat

	var body := StaticBody3D.new()
	body.collision_layer = PICK_LAYER
	body.collision_mask = 0
	body.position = pos
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = PICK_RADIUS
	shape.shape = sphere
	body.add_child(shape)
	add_child(body)
	_bodies[body] = bone_name

func _add_bone_line(a: Vector3, b: Vector3) -> void:
	var dir: Vector3 = b - a
	var length: float = dir.length()
	if length < 0.0001:
		return
	var mesh := CylinderMesh.new()
	mesh.top_radius = LINE_RADIUS
	mesh.bottom_radius = LINE_RADIUS
	mesh.height = length
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.no_depth_test = true
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = a + dir * 0.5
	# CylinderMesh's height runs along local Y; rotate Y to point along dir.
	mi.basis = Basis(Quaternion(Vector3.UP, dir.normalized()))
	add_child(mi)

func set_highlight(bone_name: String) -> void:
	if _highlighted != "" and _joint_materials.has(_highlighted):
		_joint_materials[_highlighted].emission_enabled = false
	_highlighted = bone_name
	if bone_name != "" and _joint_materials.has(bone_name):
		var mat: StandardMaterial3D = _joint_materials[bone_name]
		mat.emission_enabled = true
		mat.emission = Color(1, 1, 1)
		mat.emission_energy_multiplier = 2.0

func _unhandled_input(event: InputEvent) -> void:
	if camera == null or not visible:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var space_state := camera.get_world_3d().direct_space_state
		var query := PhysicsRayQueryParameters3D.create(
			camera.project_ray_origin(event.position),
			camera.project_ray_origin(event.position) + camera.project_ray_normal(event.position) * 100.0
		)
		query.collision_mask = PICK_LAYER
		var result := space_state.intersect_ray(query)
		if not result.is_empty() and _bodies.has(result.collider):
			bone_clicked.emit(_bodies[result.collider])
			get_viewport().set_input_as_handled()
