## Serializes the rig's pose(s) into a NWN MDL ASCII newanim/doneanim block.
## Supports either a single static pose or a full multi-keyframe animation —
## NWN's own engine interpolates between the keyframes at runtime, so we just
## need to emit one time-tagged key per keyframe, in order, per node.
class_name MdlExporter

const PARENT_ANIM := "a_ba_non_combat"

## Fixed NWN skeleton hierarchy to export (decorative meshes like cloak,
## belt, wings, tail, fb*/cl*/cm*/cr* are intentionally excluded).
## Each entry is node_name -> Dictionary of children (recursively).
const SKELETON_TREE := {
	"rootdummy": {
		"torso_g": {
			"impact": {},
			"lbicep_g": {
				"lforearm_g": {
					"lforearm": {},
					"lhand_g": {
						"lhand": {},
					},
				},
			},
			"lshoulder_g": {},
			"rbicep_g": {
				"rforearm_g": {
					"rhand_g": {
						"rhand": {},
					},
				},
			},
			"rshoulder_g": {},
			"neck_g": {
				"head_g": {
					"head": {},
				},
			},
		},
		"pelvis_g": {
			"lthigh_g": {"lshin_g": {"lfoot_g": {}}},
			"rthigh_g": {"rshin_g": {"rfoot_g": {}}},
		},
	},
}

## Convenience for the no-timeline case: exports the rig's current live pose
## as a single keyframe at time 0.0.
static func export_pose(rig_root: Node3D, anim_name: String) -> String:
	var transforms := {}
	_capture_live_transforms(rig_root, "rootdummy", SKELETON_TREE["rootdummy"], transforms)
	var keyframes: Array = [{"time": 0.0, "transforms": transforms}]
	return export_animation(rig_root, anim_name, 1.0, keyframes)

static func _capture_live_transforms(rig_root: Node3D, node_name: String, children: Dictionary, out_transforms: Dictionary) -> void:
	var node := _find_descendant(rig_root, node_name)
	if node == null:
		return
	out_transforms[node_name] = node.transform
	for child_name in children.keys():
		_capture_live_transforms(rig_root, child_name, children[child_name], out_transforms)

## Recursively captures the current transform of every node in SKELETON_TREE,
## starting from rootdummy. Used both for the no-timeline export and to seed
## a fresh keyframe when the user presses "Save to timeline".
static func capture_pose(rig_root: Node3D) -> Dictionary:
	var transforms := {}
	_capture_live_transforms(rig_root, "rootdummy", SKELETON_TREE["rootdummy"], transforms)
	return transforms

## keyframes: Array of {"time": float, "transforms": {node_name: Transform3D}},
## sorted ascending by time. length is the animation's total duration in seconds.
static func export_animation(rig_root: Node3D, anim_name: String, length: float, keyframes: Array) -> String:
	var lines: PackedStringArray = []
	lines.append("newanim %s %s" % [anim_name, PARENT_ANIM])
	lines.append("  length %s" % _fmt(length))
	lines.append("  transtime 0.25")
	lines.append("  animroot rootdummy")
	lines.append("    node dummy %s" % PARENT_ANIM)
	lines.append("        parent NULL")
	lines.append("    endnode")

	_emit_subtree(rig_root, "rootdummy", SKELETON_TREE["rootdummy"], PARENT_ANIM, lines, true, keyframes)

	lines.append("doneanim %s %s" % [anim_name, PARENT_ANIM])
	return "\n".join(lines)

static func _emit_subtree(rig_root: Node3D, node_name: String, children: Dictionary, parent_name: String, lines: PackedStringArray, is_root_dummy: bool, keyframes: Array) -> void:
	var ref_node: Node3D = _find_descendant(rig_root, node_name)
	if ref_node == null:
		push_warning("MdlExporter: node '%s' not found in rig, skipping" % node_name)
		return

	var node_type := "trimesh" if ref_node is MeshInstance3D else "dummy"
	lines.append("    node %s %s" % [node_type, node_name])
	lines.append("        parent %s" % parent_name)

	if is_root_dummy:
		lines.append("        positionkey")
		for kf in keyframes:
			var transform: Transform3D = kf["transforms"].get(node_name, Transform3D.IDENTITY)
			var pos := _to_nwn_space(transform.origin)
			lines.append("            %s %s %s %s" % [_fmt(kf["time"]), _fmt(pos.x), _fmt(pos.y), _fmt(pos.z)])
		lines.append("        endlist")

	lines.append("        orientationkey")
	for kf in keyframes:
		var transform: Transform3D = kf["transforms"].get(node_name, Transform3D.IDENTITY)
		var axis_angle := _basis_to_axis_angle(transform.basis)
		var axis := _to_nwn_space(Vector3(axis_angle.x, axis_angle.y, axis_angle.z))
		lines.append("            %s %s %s %s %s" % [
			_fmt(kf["time"]), _fmt(axis.x), _fmt(axis.y), _fmt(axis.z), _fmt(axis_angle.w)
		])
	lines.append("        endlist")
	lines.append("    endnode")

	for child_name in children.keys():
		_emit_subtree(rig_root, child_name, children[child_name], node_name, lines, false, keyframes)

## Returns Vector4(axis.x, axis.y, axis.z, angle_radians).
static func _basis_to_axis_angle(basis: Basis) -> Vector4:
	var quat := basis.get_rotation_quaternion().normalized()
	var angle := quat.get_angle()
	if angle < 0.0001:
		return Vector4(0.0, 0.0, 0.0, 0.0)
	var axis := quat.get_axis()
	return Vector4(axis.x, axis.y, axis.z, angle)

## Godot/glTF is Y-up; NWN's Aurora engine is Z-up. This is the rotation
## that converts a Godot-space vector (position or rotation axis) into
## NWN's coordinate space: nwn.x = godot.x, nwn.y = -godot.z, nwn.z = godot.y.
static func _to_nwn_space(v: Vector3) -> Vector3:
	return Vector3(v.x, -v.z, v.y)

## Inverse of _to_nwn_space, used by MdlImporter.
static func _from_nwn_space(v: Vector3) -> Vector3:
	return Vector3(v.x, v.z, -v.y)

static func _fmt(value: float) -> String:
	return "%.6f" % value

static func _find_descendant(node: Node, target_name: String) -> Node3D:
	if node.name == target_name and node is Node3D:
		return node
	for child in node.get_children():
		var found := _find_descendant(child, target_name)
		if found != null:
			return found
	return null
