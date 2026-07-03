## Converts MediaPipe world-landmark arrays into NWN rig targets.
##
## Strategy:
##   IK limbs  → set world-space IK target + pole from wrist/ankle/elbow/knee
##               landmarks, exactly like dragging the yellow handles by hand.
##   FK bones  → compute rotation from landmark direction vectors (torso, head).
##   Pelvis    → translate rootdummy to the hip-center landmark.
##
## The caller (main.gd) owns _limb_targets and the FK nodes; this script
## just returns the data, it doesn't touch the rig directly.
extends RefCounted

# ---------------------------------------------------------------------------
# MediaPipe landmark indices
# ---------------------------------------------------------------------------
const MP_NOSE           := 0
const MP_LEFT_SHOULDER  := 11
const MP_RIGHT_SHOULDER := 12
const MP_LEFT_ELBOW     := 13
const MP_RIGHT_ELBOW    := 14
const MP_LEFT_WRIST     := 15
const MP_RIGHT_WRIST    := 16
const MP_LEFT_HIP       := 23
const MP_RIGHT_HIP      := 24
const MP_LEFT_KNEE      := 25
const MP_RIGHT_KNEE     := 26
const MP_LEFT_ANKLE     := 27
const MP_RIGHT_ANKLE    := 28

# ---------------------------------------------------------------------------
# Public result structure returned by compute()
#
#   ik_targets: { component_id -> {"target": Vector3, "pole": Vector3} }
#   fk_rotations: { bone_node_name -> Quaternion (LOCAL space) }
#   root_position: Vector3 (world) or null
# ---------------------------------------------------------------------------

static func compute(world_landmarks: Array, rig_root: Node3D, scale_factor: float, origin: Vector3) -> Dictionary:
	if world_landmarks.size() < 33:
		return {}

	# Convert all 33 landmarks to world-space Vector3 using the same
	# coordinate transform as the overlay (180° Y: negate X, keep Z).
	var pts: Array[Vector3] = []
	for lm in world_landmarks:
		var vis: float = lm.get("visibility", 1.0)
		var p := Vector3(-lm["x"], -lm["y"], lm["z"]) * scale_factor + origin
		pts.append(p)

	var vis: Array = []
	for lm in world_landmarks:
		vis.append(lm.get("visibility", 1.0))

	var result := {
		"ik_targets": {},
		"fk_rotations": {},
		"root_position": null,
	}

	# ------------------------------------------------------------------
	# IK targets: right arm, left arm, right leg, left leg
	# ------------------------------------------------------------------
	if vis[MP_RIGHT_WRIST] >= 0.4 and vis[MP_RIGHT_ELBOW] >= 0.4:
		result["ik_targets"]["right_arm"] = {
			"target": pts[MP_RIGHT_WRIST],
			"pole":   pts[MP_RIGHT_ELBOW],
		}
	if vis[MP_LEFT_WRIST] >= 0.4 and vis[MP_LEFT_ELBOW] >= 0.4:
		result["ik_targets"]["left_arm"] = {
			"target": pts[MP_LEFT_WRIST],
			"pole":   pts[MP_LEFT_ELBOW],
		}
	if vis[MP_RIGHT_ANKLE] >= 0.4 and vis[MP_RIGHT_KNEE] >= 0.4:
		result["ik_targets"]["right_leg"] = {
			"target": pts[MP_RIGHT_ANKLE],
			"pole":   pts[MP_RIGHT_KNEE],
		}
	if vis[MP_LEFT_ANKLE] >= 0.4 and vis[MP_LEFT_KNEE] >= 0.4:
		result["ik_targets"]["left_leg"] = {
			"target": pts[MP_LEFT_ANKLE],
			"pole":   pts[MP_LEFT_KNEE],
		}

	# ------------------------------------------------------------------
	# FK: torso rotation — direction from hip centre to shoulder centre
	# ------------------------------------------------------------------
	if vis[MP_LEFT_HIP] >= 0.4 and vis[MP_RIGHT_HIP] >= 0.4 and \
	   vis[MP_LEFT_SHOULDER] >= 0.4 and vis[MP_RIGHT_SHOULDER] >= 0.4:

		var hip_center    := (pts[MP_LEFT_HIP]      + pts[MP_RIGHT_HIP])      * 0.5
		var shoulder_center := (pts[MP_LEFT_SHOULDER] + pts[MP_RIGHT_SHOULDER]) * 0.5
		var spine_dir     := (shoulder_center - hip_center).normalized()

		var torso_node: Node3D = _find(rig_root, "torso_g")
		if torso_node != null:
			var parent_basis := torso_node.get_parent().global_basis if torso_node.get_parent() is Node3D else Basis.IDENTITY
			var local_dir := parent_basis.inverse() * spine_dir
			result["fk_rotations"]["torso_g"] = Quaternion(Vector3.UP, local_dir)

		# Pelvis position: move rootdummy so the hip midpoint matches
		var rootdummy: Node3D = _find(rig_root, "rootdummy")
		if rootdummy != null:
			var rest_hip_center := (
				_find(rig_root, "lthigh_g").global_position +
				_find(rig_root, "rthigh_g").global_position
			) * 0.5 if _find(rig_root, "lthigh_g") != null and _find(rig_root, "rthigh_g") != null \
			else rootdummy.global_position
			var offset := hip_center - rest_hip_center
			result["root_position"] = rootdummy.global_position + offset

	# ------------------------------------------------------------------
	# FK: head — direction from shoulder centre to nose
	# ------------------------------------------------------------------
	if vis[MP_NOSE] >= 0.4 and vis[MP_LEFT_SHOULDER] >= 0.4 and vis[MP_RIGHT_SHOULDER] >= 0.4:
		var shoulder_center := (pts[MP_LEFT_SHOULDER] + pts[MP_RIGHT_SHOULDER]) * 0.5
		var head_dir := (pts[MP_NOSE] - shoulder_center).normalized()
		var head_node: Node3D = _find(rig_root, "head_g")
		if head_node != null:
			var parent_basis := head_node.get_parent().global_basis if head_node.get_parent() is Node3D else Basis.IDENTITY
			var local_dir := parent_basis.inverse() * head_dir
			result["fk_rotations"]["head_g"] = Quaternion(Vector3.UP, local_dir)

	return result


static func _find(node: Node, target: String) -> Node3D:
	if node.name == target and node is Node3D:
		return node
	for child in node.get_children():
		var found := _find(child, target)
		if found != null:
			return found
	return null
