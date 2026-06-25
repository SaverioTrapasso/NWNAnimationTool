extends Node3D

## Builds pick colliders for the selectable components of the rig, handles
## mouse-click selection, and highlights the currently selected component.
## Decorative meshes (cloak, belt, wings, tail, fb*/cl*/cm*/cr*, etc.) are
## never given a pick collider, so they cannot be selected.

signal component_selected(component_id: String)
signal component_deselected()

@export var camera: Camera3D
@export var rig_root: Node3D

var _node_to_component: Dictionary
var _component_meshes: Dictionary # component_id -> Array[MeshInstance3D]
var _component_bodies: Dictionary # component_id -> Array[StaticBody3D]
var _highlight_materials: Dictionary # MeshInstance3D -> original material (or null)
var selected_component: String = ""

func _ready() -> void:
	_node_to_component = RigComponents.node_to_component_map()

## Must be called once camera and rig_root have been assigned.
func setup() -> void:
	_build_pick_colliders()

func _build_pick_colliders() -> void:
	for component_id in _node_to_component.values():
		if not _component_meshes.has(component_id):
			_component_meshes[component_id] = []
			_component_bodies[component_id] = []

	for node_name in _node_to_component.keys():
		var mesh_node := _find_descendant(rig_root, node_name)
		if mesh_node == null or not (mesh_node is MeshInstance3D):
			push_warning("RigController: node '%s' not found or not a MeshInstance3D" % node_name)
			continue
		var component_id: String = _node_to_component[node_name]
		_component_meshes[component_id].append(mesh_node)

		var aabb: AABB = mesh_node.get_aabb()
		var body := StaticBody3D.new()
		body.name = "PickBody_%s" % node_name
		body.collision_layer = RigComponents.PICK_LAYER
		body.collision_mask = 0
		body.set_meta("component_id", component_id)

		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = aabb.size * 1.05 # slight padding so thin parts are easier to click
		shape.shape = box
		shape.position = aabb.get_center()
		body.add_child(shape)

		mesh_node.add_child(body)
		_component_bodies[component_id].append(body)

func _find_descendant(node: Node, target_name: String) -> Node:
	if node.name == target_name:
		return node
	for child in node.get_children():
		var found := _find_descendant(child, target_name)
		if found != null:
			return found
	return null

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_try_pick(event.position)

func _try_pick(screen_pos: Vector2) -> void:
	if camera == null:
		return
	var space_state := camera.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		camera.project_ray_origin(screen_pos),
		camera.project_ray_origin(screen_pos) + camera.project_ray_normal(screen_pos) * 100.0
	)
	query.collision_mask = RigComponents.PICK_LAYER
	var result := space_state.intersect_ray(query)
	if result.is_empty():
		_deselect()
		return
	var body: Node = result.collider
	var component_id: String = body.get_meta("component_id", "")
	if component_id == "":
		_deselect()
		return
	select_component(component_id)

func select_component(component_id: String) -> void:
	if component_id == selected_component:
		return
	_clear_highlight()
	selected_component = component_id
	_apply_highlight(component_id)
	component_selected.emit(component_id)

func _deselect() -> void:
	if selected_component == "":
		return
	_clear_highlight()
	selected_component = ""
	component_deselected.emit()

func _apply_highlight(component_id: String) -> void:
	for mesh_node in _component_meshes.get(component_id, []):
		var mat := StandardMaterial3D.new()
		var base_mat: Material = mesh_node.get_active_material(0)
		if base_mat is BaseMaterial3D:
			mat.albedo_color = base_mat.albedo_color
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.55, 0.0)
		mat.emission_energy_multiplier = 0.8
		_highlight_materials[mesh_node] = mesh_node.material_overlay
		mesh_node.material_overlay = mat

func _clear_highlight() -> void:
	for mesh_node in _highlight_materials.keys():
		mesh_node.material_overlay = _highlight_materials[mesh_node]
	_highlight_materials.clear()

func get_component_chain(component_id: String) -> Array[String]:
	for comp in RigComponents.definitions():
		if comp.id == component_id:
			return comp.chain
	return []

func get_component_root_node(component_id: String) -> Node3D:
	var chain := get_component_chain(component_id)
	if chain.is_empty():
		return null
	return _find_descendant(rig_root, chain[0])

## Finds any node in the rig by its NWN node name, regardless of component.
func find_node(node_name: String) -> Node3D:
	var found := _find_descendant(rig_root, node_name)
	return found if found is Node3D else null

## Returns the chain's nodes (root..tip) as actual Node3D instances.
func get_chain_nodes(component_id: String) -> Array[Node3D]:
	var nodes: Array[Node3D] = []
	for node_name in get_component_chain(component_id):
		var found := _find_descendant(rig_root, node_name)
		if found is Node3D:
			nodes.append(found)
	return nodes
