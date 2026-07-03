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
	# FK: pelvis + torso — build a full Basis from two support midpoints
	#
	# support_hip      = midpoint of left_hip  and right_hip  landmarks
	# support_shoulder = midpoint of left_shoulder and right_shoulder
	#
	# From these two points we derive three orthogonal world-space axes:
	#   Y (up)      = (support_shoulder - support_hip).normalized()
	#   X (right)   = (right_hip - left_hip).normalized(), then
	#                 orthogonalised w.r.t. Y (Gram-Schmidt)
	#   Z (forward) = X.cross(Y)
	#
	# The local rotation for each bone is then:
	#   rot = target_basis * bone_rest_global_basis.inverse()
	# converted to local space via the parent's global basis.
	# ------------------------------------------------------------------
	if vis[MP_LEFT_HIP] >= 0.4 and vis[MP_RIGHT_HIP] >= 0.4 and \
	   vis[MP_LEFT_SHOULDER] >= 0.4 and vis[MP_RIGHT_SHOULDER] >= 0.4:

		var support_hip      := (pts[MP_LEFT_HIP]      + pts[MP_RIGHT_HIP])      * 0.5
		var support_shoulder := (pts[MP_LEFT_SHOULDER] + pts[MP_RIGHT_SHOULDER]) * 0.5

		# After the 180° Y-flip: left_hip is pts[MP_LEFT_HIP], right is pts[MP_RIGHT_HIP].
		# Lateral axis points from left to right in world space.
		var axis_y := (support_shoulder - support_hip).normalized()
		var axis_x := (pts[MP_RIGHT_HIP] - pts[MP_LEFT_HIP]).normalized()
		axis_x = (axis_x - axis_y * axis_y.dot(axis_x)).normalized()  # Gram-Schmidt
		var axis_z := axis_x.cross(axis_y).normalized()
		var target_basis := Basis(axis_x, axis_y, axis_z)

		# --- Pelvis ---
		var pelvis_node: Node3D = _find(rig_root, "pelvis_g")
		if pelvis_node != null:
			var rest_global_basis := pelvis_node.global_basis
			var parent_node := pelvis_node.get_parent()
			var parent_global_basis: Basis = parent_node.global_basis if parent_node is Node3D else Basis.IDENTITY
			var rot_global := target_basis * rest_global_basis.inverse()
			result["fk_rotations"]["pelvis_g"] = Quaternion(parent_global_basis.inverse() * rot_global * parent_global_basis)

		# --- Torso ---
		var torso_node: Node3D = _find(rig_root, "torso_g")
		if torso_node != null:
			var rest_global_basis := torso_node.global_basis
			var parent_node := torso_node.get_parent()
			var parent_global_basis: Basis = parent_node.global_basis if parent_node is Node3D else Basis.IDENTITY
			var rot_global := target_basis * rest_global_basis.inverse()
			result["fk_rotations"]["torso_g"] = Quaternion(parent_global_basis.inverse() * rot_global * parent_global_basis)

		# --- Rootdummy position: shift so support_hip lands on the rig's hip midpoint ---
		var rootdummy: Node3D = _find(rig_root, "rootdummy")
		var lthigh: Node3D   = _find(rig_root, "lthigh_g")
		var rthigh: Node3D   = _find(rig_root, "rthigh_g")
		if rootdummy != null and lthigh != null and rthigh != null:
			var rig_hip_center := (lthigh.global_position + rthigh.global_position) * 0.5
			result["root_position"] = rootdummy.global_position + (support_hip - rig_hip_center)

	# ------------------------------------------------------------------
	# FK: head — use shoulder→nose direction, same Basis approach
	# ------------------------------------------------------------------
	if vis[MP_NOSE] >= 0.4 and vis[MP_LEFT_SHOULDER] >= 0.4 and vis[MP_RIGHT_SHOULDER] >= 0.4:
		var support_shoulder := (pts[MP_LEFT_SHOULDER] + pts[MP_RIGHT_SHOULDER]) * 0.5
		var head_dir := (pts[MP_NOSE] - support_shoulder).normalized()
		var head_node: Node3D = _find(rig_root, "head_g")
		if head_node != null:
			var rest_global_basis := head_node.global_basis
			var parent_node := head_node.get_parent()
			var parent_global_basis: Basis = parent_node.global_basis if parent_node is Node3D else Basis.IDENTITY
			# Build a basis with Y pointing toward the nose
			var h_axis_y := head_dir
			var h_axis_x := rest_global_basis.x  # keep lateral axis from rest
			h_axis_x = (h_axis_x - h_axis_y * h_axis_y.dot(h_axis_x)).normalized()
			var h_axis_z := h_axis_x.cross(h_axis_y).normalized()
			var target_head_basis := Basis(h_axis_x, h_axis_y, h_axis_z)
			var rot_global := target_head_basis * rest_global_basis.inverse()
			result["fk_rotations"]["head_g"] = Quaternion(parent_global_basis.inverse() * rot_global * parent_global_basis)

	return result


static func _find(node: Node, target: String) -> Node3D:
	if node.name == target and node is Node3D:
		return node
	for child in node.get_children():
		var found := _find(child, target)
		if found != null:
			return found
	return null
