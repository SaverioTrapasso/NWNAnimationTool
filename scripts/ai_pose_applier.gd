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
const MP_NOSE             := 0
const MP_LEFT_EAR         := 7
const MP_RIGHT_EAR        := 8
const MP_LEFT_SHOULDER    := 11
const MP_RIGHT_SHOULDER   := 12
const MP_LEFT_ELBOW       := 13
const MP_RIGHT_ELBOW      := 14
const MP_LEFT_WRIST       := 15
const MP_RIGHT_WRIST      := 16
const MP_LEFT_PINKY       := 17
const MP_RIGHT_PINKY      := 18
const MP_LEFT_INDEX       := 19
const MP_RIGHT_INDEX      := 20
const MP_LEFT_THUMB       := 21
const MP_RIGHT_THUMB      := 22
const MP_LEFT_HIP         := 23
const MP_RIGHT_HIP        := 24
const MP_LEFT_KNEE        := 25
const MP_RIGHT_KNEE       := 26
const MP_LEFT_ANKLE       := 27
const MP_RIGHT_ANKLE      := 28
const MP_LEFT_HEEL        := 29
const MP_RIGHT_HEEL       := 30
const MP_LEFT_FOOT_INDEX  := 31
const MP_RIGHT_FOOT_INDEX := 32

# ---------------------------------------------------------------------------
# Public result structure returned by compute()
#
#   ik_targets: { component_id -> {"target": Vector3, "pole": Vector3} }
#   fk_rotations: { bone_node_name -> Quaternion (LOCAL space) }
#   root_position: Vector3 (world) or null
# ---------------------------------------------------------------------------

static func compute(world_landmarks: Array, rig_root: Node3D, scale_factor: float, origin: Vector3, pre_rotation: Quaternion = Quaternion.IDENTITY, calibration: Dictionary = {}) -> Dictionary:
	if world_landmarks.size() < 33:
		return {}

	# Convert all 33 landmarks to world-space Vector3 using the same
	# coordinate transform as the overlay (180° Y: negate X, keep Z).
	# pre_rotation levels out MediaPipe's estimated-world tilt (computed
	# once from the first frame via compute_ground_alignment).
	var pre_basis := Basis(pre_rotation)
	var pts: Array[Vector3] = []
	for lm in world_landmarks:
		var p := pre_basis * Vector3(-lm["x"], -lm["y"], lm["z"]) * scale_factor + origin
		pts.append(p)

	var vis: Array = []
	for lm in world_landmarks:
		vis.append(lm.get("visibility", 1.0))

	# Ground the entire skeleton: shift all pts down so the lowest foot
	# CONTACT point (heel or toe — not the ankle, which sits above the
	# sole) rests at Y=0. Done here before anything else so every derived
	# point (IK targets, midpoints, FK bases) inherits the correction.
	var min_foot_y: float = min(
		min(pts[MP_LEFT_HEEL].y, pts[MP_RIGHT_HEEL].y),
		min(pts[MP_LEFT_FOOT_INDEX].y, pts[MP_RIGHT_FOOT_INDEX].y)
	)
	for i in range(pts.size()):
		pts[i].y -= min_foot_y

	var result := {
		"ik_targets": {},
		"fk_rotations": {},
		"root_position": null,
	}

	# ------------------------------------------------------------------
	# IK targets: right arm, left arm, right leg, left leg
	# ------------------------------------------------------------------
	# Pole vector formula: midpoint between root and tip of the limb,
	# then project outward through the mid-joint (elbow/knee) doubling
	# the distance — pole = 2*mid_joint - midpoint(root, tip).
	# This guarantees the pole is always on the correct side and at a
	# safe distance regardless of how extreme the pose is.
	if vis[MP_RIGHT_SHOULDER] >= 0.4 and vis[MP_RIGHT_WRIST] >= 0.4 and vis[MP_RIGHT_ELBOW] >= 0.4:
		var mid := (pts[MP_RIGHT_SHOULDER] + pts[MP_RIGHT_WRIST]) * 0.5
		result["ik_targets"]["right_arm"] = {
			"target": pts[MP_RIGHT_WRIST],
			"pole":   pts[MP_RIGHT_ELBOW] * 2.0 - mid,
		}
	if vis[MP_LEFT_SHOULDER] >= 0.4 and vis[MP_LEFT_WRIST] >= 0.4 and vis[MP_LEFT_ELBOW] >= 0.4:
		var mid := (pts[MP_LEFT_SHOULDER] + pts[MP_LEFT_WRIST]) * 0.5
		result["ik_targets"]["left_arm"] = {
			"target": pts[MP_LEFT_WRIST],
			"pole":   pts[MP_LEFT_ELBOW] * 2.0 - mid,
		}
	if vis[MP_RIGHT_HIP] >= 0.4 and vis[MP_RIGHT_ANKLE] >= 0.4 and vis[MP_RIGHT_KNEE] >= 0.4:
		var mid := (pts[MP_RIGHT_HIP] + pts[MP_RIGHT_ANKLE]) * 0.5
		result["ik_targets"]["right_leg"] = {
			"target": pts[MP_RIGHT_ANKLE],
			"pole":   pts[MP_RIGHT_KNEE] * 2.0 - mid,
		}
	if vis[MP_LEFT_HIP] >= 0.4 and vis[MP_LEFT_ANKLE] >= 0.4 and vis[MP_LEFT_KNEE] >= 0.4:
		var mid := (pts[MP_LEFT_HIP] + pts[MP_LEFT_ANKLE]) * 0.5
		result["ik_targets"]["left_leg"] = {
			"target": pts[MP_LEFT_ANKLE],
			"pole":   pts[MP_LEFT_KNEE] * 2.0 - mid,
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
	# target_basis is already in world space. To get the local quaternion:
	#   new_local_basis = parent_global_basis.inverse() * target_basis
	# ------------------------------------------------------------------
	if vis[MP_LEFT_HIP] >= 0.4 and vis[MP_RIGHT_HIP] >= 0.4 and \
	   vis[MP_LEFT_SHOULDER] >= 0.4 and vis[MP_RIGHT_SHOULDER] >= 0.4:

		var support_hip      := (pts[MP_LEFT_HIP]      + pts[MP_RIGHT_HIP])      * 0.5
		var support_shoulder := (pts[MP_LEFT_SHOULDER] + pts[MP_RIGHT_SHOULDER]) * 0.5

		var axis_y := (support_shoulder - support_hip).normalized()
		var axis_x := (pts[MP_RIGHT_HIP] - pts[MP_LEFT_HIP]).normalized()
		axis_x = (axis_x - axis_y * axis_y.dot(axis_x)).normalized()
		var axis_z := axis_x.cross(axis_y).normalized()
		var target_basis := Basis(axis_x, axis_y, axis_z)

		# --- Pelvis ---
		var pelvis_node: Node3D = _find(rig_root, "pelvis_g")
		if pelvis_node != null:
			var parent_node := pelvis_node.get_parent()
			var parent_global_basis: Basis = parent_node.global_basis if parent_node is Node3D else Basis.IDENTITY
			result["fk_rotations"]["pelvis_g"] = Quaternion(parent_global_basis.inverse() * target_basis)

		# --- Torso ---
		var torso_node: Node3D = _find(rig_root, "torso_g")
		if torso_node != null:
			var parent_node := torso_node.get_parent()
			var parent_global_basis: Basis = parent_node.global_basis if parent_node is Node3D else Basis.IDENTITY
			result["fk_rotations"]["torso_g"] = Quaternion(parent_global_basis.inverse() * target_basis)

		# --- Rootdummy position ---
		var rootdummy: Node3D = _find(rig_root, "rootdummy")
		var lthigh: Node3D   = _find(rig_root, "lthigh_g")
		var rthigh: Node3D   = _find(rig_root, "rthigh_g")
		if rootdummy != null and lthigh != null and rthigh != null:
			var rig_hip_center := (lthigh.global_position + rthigh.global_position) * 0.5
			result["root_position"] = rootdummy.global_position + (support_hip - rig_hip_center)

	# ------------------------------------------------------------------
	# FK: hands — build Basis from wrist + index knuckle + pinky knuckle
	#
	# For each hand:
	#   axis_x (across) = pinky_knuckle → index_knuckle (right = thumb side)
	#   axis_z (fingers) = wrist → index_knuckle, orthogonalised vs axis_x
	#   axis_y (dorsal)  = axis_z.cross(axis_x)
	# ------------------------------------------------------------------
	_apply_end_bone_fk(rig_root, result, calibration, "rhand_g",
		_hand_conv_basis(pts, vis, MP_RIGHT_WRIST, MP_RIGHT_INDEX, MP_RIGHT_PINKY, true))
	_apply_end_bone_fk(rig_root, result, calibration, "lhand_g",
		_hand_conv_basis(pts, vis, MP_LEFT_WRIST, MP_LEFT_INDEX, MP_LEFT_PINKY, false))

	# ------------------------------------------------------------------
	# FK: feet — build Basis from heel + foot_index (toe) + knee for "up"
	#
	#   axis_z (forward) = heel → foot_index (toe direction)
	#   axis_y reference = knee → ankle (shin direction, down leg)
	#   axis_x (lateral) = axis_z.cross(shin_ref), orthogonalised
	#   axis_y (dorsal)  = axis_x.cross(axis_z)
	# ------------------------------------------------------------------
	_apply_end_bone_fk(rig_root, result, calibration, "rfoot_g",
		_foot_conv_basis(pts, vis, MP_RIGHT_HEEL, MP_RIGHT_FOOT_INDEX, MP_RIGHT_KNEE, MP_RIGHT_ANKLE))
	_apply_end_bone_fk(rig_root, result, calibration, "lfoot_g",
		_foot_conv_basis(pts, vis, MP_LEFT_HEEL, MP_LEFT_FOOT_INDEX, MP_LEFT_KNEE, MP_LEFT_ANKLE))

	# ------------------------------------------------------------------
	# FK: head — ear midpoint up toward shoulder midpoint
	# ------------------------------------------------------------------
	if vis[MP_LEFT_EAR] >= 0.4 and vis[MP_RIGHT_EAR] >= 0.4 and \
	   vis[MP_LEFT_SHOULDER] >= 0.4 and vis[MP_RIGHT_SHOULDER] >= 0.4:
		var support_ear      := (pts[MP_LEFT_EAR]      + pts[MP_RIGHT_EAR])      * 0.5
		var support_shoulder := (pts[MP_LEFT_SHOULDER] + pts[MP_RIGHT_SHOULDER]) * 0.5
		var h_axis_y := (support_ear - support_shoulder).normalized()
		var h_axis_x := (pts[MP_RIGHT_EAR] - pts[MP_LEFT_EAR]).normalized()
		h_axis_x = (h_axis_x - h_axis_y * h_axis_y.dot(h_axis_x)).normalized()
		var h_axis_z := h_axis_x.cross(h_axis_y).normalized()
		var target_head_basis := Basis(h_axis_x, h_axis_y, h_axis_z)
		var head_node: Node3D = _find(rig_root, "head_g")
		if head_node != null:
			var parent_node := head_node.get_parent()
			var parent_global_basis: Basis = parent_node.global_basis if parent_node is Node3D else Basis.IDENTITY
			result["fk_rotations"]["head_g"] = Quaternion(parent_global_basis.inverse() * target_head_basis)

	return result


# ---------------------------------------------------------------------------
# Convention-basis builders — return a world-space Basis describing the hand/
# foot orientation in a FIXED convention (X across, Y dorsal, Z along), or
# null when the landmarks aren't visible enough. The convention itself is
# arbitrary: any constant mismatch with the rig bone's own axes cancels out
# through the first-frame calibration offset (see compute_rest_calibration).
# ---------------------------------------------------------------------------

static func _hand_conv_basis(pts: Array, vis: Array,
		wrist_idx: int, index_idx: int, pinky_idx: int, is_right: bool) -> Variant:
	var VIS_THRESH := 0.4
	if vis[wrist_idx] < VIS_THRESH or vis[index_idx] < VIS_THRESH or vis[pinky_idx] < VIS_THRESH:
		return null

	# Fingers direction: wrist → index knuckle
	var axis_z: Vector3 = (pts[index_idx] - pts[wrist_idx]).normalized()
	# Across knuckles: for right hand pinky→index = +X (thumb side); mirror for left
	var across: Vector3 = (pts[index_idx] - pts[pinky_idx]).normalized()
	if not is_right:
		across = -across
	# Gram-Schmidt: orthogonalise across vs fingers
	var axis_x: Vector3 = (across - axis_z * axis_z.dot(across)).normalized()
	var axis_y: Vector3 = axis_z.cross(axis_x).normalized()
	return Basis(axis_x, axis_y, axis_z)


static func _foot_conv_basis(pts: Array, vis: Array,
		heel_idx: int, toe_idx: int, knee_idx: int, ankle_idx: int) -> Variant:
	var VIS_THRESH := 0.35
	if vis[heel_idx] < VIS_THRESH or vis[toe_idx] < VIS_THRESH or vis[ankle_idx] < VIS_THRESH:
		return null

	# Foot forward: heel → toe
	var axis_z: Vector3 = (pts[toe_idx] - pts[heel_idx]).normalized()
	# Shin reference for lateral: knee → ankle points down the leg
	var shin_ref: Vector3 = (pts[ankle_idx] - pts[knee_idx]).normalized() if vis[knee_idx] >= VIS_THRESH \
		else Vector3(0.0, -1.0, 0.0)
	# Lateral axis: perpendicular to both forward and shin, then orthogonalised
	var axis_x: Vector3 = axis_z.cross(shin_ref).normalized()
	axis_x = (axis_x - axis_z * axis_z.dot(axis_x)).normalized()
	var axis_y: Vector3 = axis_x.cross(axis_z).normalized()
	return Basis(axis_x, axis_y, axis_z)


## Applies a convention basis to an end bone, routing through the per-bone
## calibration offset when one is available.
static func _apply_end_bone_fk(rig_root: Node3D, result: Dictionary,
		calibration: Dictionary, bone_name: String, conv_basis: Variant) -> void:
	if not (conv_basis is Basis):
		return
	var bone: Node3D = _find(rig_root, bone_name)
	if bone == null:
		return
	var parent := bone.get_parent()
	var parent_global_basis: Basis = parent.global_basis if parent is Node3D else Basis.IDENTITY
	var local := Quaternion(parent_global_basis.inverse() * (conv_basis as Basis))
	if calibration.has(bone_name):
		local = local * calibration[bone_name]
	result["fk_rotations"][bone_name] = local


## Computes the corrective rotation that levels MediaPipe's estimated world
## using the FIRST frame of a grounded animation. Fits a plane through the
## four foot contact points (both heels + both toes, via the diagonals of
## the contact quad) and rotates that plane's normal onto world UP — one
## robust measurement instead of trusting any single heel→toe direction,
## which is noisy enough to tip the whole body over.
## Corrections beyond MAX_CORRECTION_DEG are distrusted (the first frame is
## probably not flat-footed) and identity is returned instead.
## Apply the result as compute()'s pre_rotation for every frame.
const MAX_CORRECTION_DEG := 25.0

static func compute_ground_alignment(world_landmarks: Array) -> Quaternion:
	if world_landmarks.size() < 33:
		return Quaternion.IDENTITY
	var pts: Array[Vector3] = []
	for lm in world_landmarks:
		pts.append(Vector3(-lm["x"], -lm["y"], lm["z"]))

	var l_heel: Vector3 = pts[MP_LEFT_HEEL]
	var l_toe: Vector3  = pts[MP_LEFT_FOOT_INDEX]
	var r_heel: Vector3 = pts[MP_RIGHT_HEEL]
	var r_toe: Vector3  = pts[MP_RIGHT_FOOT_INDEX]

	# Plane normal from the diagonals of the contact quad — uses all four
	# points at once, so a single noisy landmark can't dominate the fit.
	var normal: Vector3 = (r_toe - l_heel).cross(l_toe - r_heel)
	if normal.length() < 0.0001:
		print("[GroundAlign] contact points degenerate, skipping correction")
		return Quaternion.IDENTITY
	normal = normal.normalized()
	if normal.y < 0.0:
		normal = -normal

	var angle_deg := rad_to_deg(normal.angle_to(Vector3.UP))
	if angle_deg > MAX_CORRECTION_DEG:
		print("[GroundAlign] correction %.1f° exceeds %.0f° limit — first frame not flat? Skipping." % [angle_deg, MAX_CORRECTION_DEG])
		return Quaternion.IDENTITY

	print("[GroundAlign] applying %.1f° world-tilt correction" % angle_deg)
	return Quaternion(normal, Vector3.UP)


## Measures the constant offset between the MediaPipe hand/foot convention
## and each rig bone's own axes, using the first frame of the video while
## the RIG IS STILL AT REST. Assumes the first frame shows hands/feet in a
## roughly neutral orientation (true for grounded combat-stance videos).
## Returns { bone_name: Quaternion } to pass as compute()'s calibration.
static func compute_rest_calibration(world_landmarks: Array, rig_root: Node3D,
		scale_factor: float, origin: Vector3, pre_rotation: Quaternion = Quaternion.IDENTITY) -> Dictionary:
	if world_landmarks.size() < 33:
		return {}

	var pre_basis := Basis(pre_rotation)
	var pts: Array[Vector3] = []
	for lm in world_landmarks:
		pts.append(pre_basis * Vector3(-lm["x"], -lm["y"], lm["z"]) * scale_factor + origin)
	var vis: Array = []
	for lm in world_landmarks:
		vis.append(lm.get("visibility", 1.0))

	var conv_bases := {
		"rhand_g": _hand_conv_basis(pts, vis, MP_RIGHT_WRIST, MP_RIGHT_INDEX, MP_RIGHT_PINKY, true),
		"lhand_g": _hand_conv_basis(pts, vis, MP_LEFT_WRIST, MP_LEFT_INDEX, MP_LEFT_PINKY, false),
		"rfoot_g": _foot_conv_basis(pts, vis, MP_RIGHT_HEEL, MP_RIGHT_FOOT_INDEX, MP_RIGHT_KNEE, MP_RIGHT_ANKLE),
		"lfoot_g": _foot_conv_basis(pts, vis, MP_LEFT_HEEL, MP_LEFT_FOOT_INDEX, MP_LEFT_KNEE, MP_LEFT_ANKLE),
	}

	var calibration := {}
	for bone_name in conv_bases:
		var conv: Variant = conv_bases[bone_name]
		if not (conv is Basis):
			continue
		var bone: Node3D = _find(rig_root, bone_name)
		if bone == null:
			continue
		var parent := bone.get_parent()
		var parent_global_basis: Basis = parent.global_basis if parent is Node3D else Basis.IDENTITY
		var raw_local := Quaternion(parent_global_basis.inverse() * (conv as Basis))
		# offset such that: raw_local(frame 1) * offset == bone's rest local
		calibration[bone_name] = raw_local.inverse() * bone.quaternion
	return calibration


static func _find(node: Node, target: String) -> Node3D:
	if node.name == target and node is Node3D:
		return node
	for child in node.get_children():
		var found := _find(child, target)
		if found != null:
			return found
	return null
