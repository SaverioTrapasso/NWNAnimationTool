## Converts MediaPipe world-landmark arrays into NWN bone rotations and
## applies them to the live rig.
##
## MediaPipe world-landmark coordinate system:
##   +X  right of person,  +Y  up,  +Z  toward camera
##   origin at the midpoint of the two hips
##
## NWN / Godot rig coordinate system (Y-up, right-handed):
##   We work in global space and let the existing FK / IK pipeline handle
##   the per-bone local transforms.
##
## Mapping strategy: for each NWN bone we pick two MediaPipe landmarks that
## define the bone's direction vector, then derive a rotation that points the
## bone's default rest axis along that direction.
extends RefCounted

# ---------------------------------------------------------------------------
# MediaPipe landmark indices
# ---------------------------------------------------------------------------
const MP := {
	NOSE          = 0,
	LEFT_EYE      = 2,
	RIGHT_EYE     = 5,
	LEFT_EAR      = 7,
	RIGHT_EAR     = 8,
	LEFT_SHOULDER = 11,
	RIGHT_SHOULDER= 12,
	LEFT_ELBOW    = 13,
	RIGHT_ELBOW   = 14,
	LEFT_WRIST    = 15,
	RIGHT_WRIST   = 16,
	LEFT_HIP      = 23,
	RIGHT_HIP     = 24,
	LEFT_KNEE     = 25,
	RIGHT_KNEE    = 26,
	LEFT_ANKLE    = 27,
	RIGHT_ANKLE   = 28,
}

# ---------------------------------------------------------------------------
# Bone → (from_landmark, to_landmark) pairs
# "from" is the proximal end, "to" is the distal end.
# The bone's rest direction in Godot's local space is assumed to be +Y.
# ---------------------------------------------------------------------------
const BONE_LANDMARK_PAIRS := {
	# Spine / torso
	"pelvis_g":   [MP.LEFT_HIP,       MP.RIGHT_HIP],       # lateral hip axis → pelvis roll
	"torso_g":    [MP.LEFT_HIP,       MP.LEFT_SHOULDER],   # spine direction

	# Right arm
	"rbicep_g":   [MP.RIGHT_SHOULDER, MP.RIGHT_ELBOW],
	"rforearm_g": [MP.RIGHT_ELBOW,    MP.RIGHT_WRIST],

	# Left arm
	"lbicep_g":   [MP.LEFT_SHOULDER,  MP.LEFT_ELBOW],
	"lforearm_g": [MP.LEFT_ELBOW,     MP.LEFT_WRIST],

	# Right leg
	"rthigh_g":   [MP.RIGHT_HIP,      MP.RIGHT_KNEE],
	"rshin_g":    [MP.RIGHT_KNEE,     MP.RIGHT_ANKLE],

	# Left leg
	"lthigh_g":   [MP.LEFT_HIP,       MP.LEFT_KNEE],
	"lshin_g":    [MP.LEFT_KNEE,      MP.LEFT_ANKLE],
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## world_landmarks: Array of Dicts with keys x,y,z,name,visibility
## rig_root: the Node3D root of the NWN rig
## Returns a dict of nwn_bone_name -> Quaternion (global-space)
static func landmarks_to_rotations(world_landmarks: Array, rig_root: Node3D) -> Dictionary:
	if world_landmarks.size() < 33:
		return {}

	var pts: Array[Vector3] = []
	for lm in world_landmarks:
		# MediaPipe: X right, Y up, Z toward camera → Godot: X right, Y up, Z toward camera ✓
		pts.append(Vector3(lm["x"], -lm["y"], -lm["z"]))  # flip Y and Z for Godot Y-up right-hand

	var result := {}
	for bone_name in BONE_LANDMARK_PAIRS:
		var pair: Array = BONE_LANDMARK_PAIRS[bone_name]
		var from_idx: int = pair[0]
		var to_idx: int   = pair[1]

		if from_idx >= pts.size() or to_idx >= pts.size():
			continue

		var dir: Vector3 = (pts[to_idx] - pts[from_idx]).normalized()
		if dir.length_squared() < 0.001:
			continue

		# Visibility gate: skip landmarks the model isn't confident about
		var vis_from: float = world_landmarks[from_idx].get("visibility", 1.0)
		var vis_to:   float = world_landmarks[to_idx].get("visibility", 1.0)
		if vis_from < 0.3 or vis_to < 0.3:
			continue

		# Find the bone node in the rig and compute the local rotation
		# needed to align its rest axis (+Y in local space) with the
		# world-space direction we derived from MediaPipe.
		var bone_node := _find_descendant(rig_root, bone_name)
		if bone_node == null:
			continue

		var local_dir: Vector3 = bone_node.get_parent().global_transform.basis.inverse() * dir
		var rest_axis := Vector3.UP  # bones point along +Y in rest pose
		var q := Quaternion(rest_axis, local_dir)
		result[bone_name] = q

	return result


## Apply the rotation dict to the live rig nodes.
static func apply_rotations(rotations: Dictionary, rig_root: Node3D) -> void:
	for bone_name in rotations:
		var node := _find_descendant(rig_root, bone_name)
		if node == null:
			continue
		node.quaternion = rotations[bone_name]


static func _find_descendant(node: Node, target: String) -> Node3D:
	if node.name == target and node is Node3D:
		return node
	for child in node.get_children():
		var found := _find_descendant(child, target)
		if found != null:
			return found
	return null
