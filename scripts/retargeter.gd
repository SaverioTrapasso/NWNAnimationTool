## Bakes an animation from a foreign skeleton (e.g. FF14) onto the NWN rig's
## rest pose, bone-by-bone, using a name-based bone_map. No IK is involved —
## NWN's export only needs local rotations (+ rootdummy position), so this
## is a straight FK rotation copy with a rest-pose delta:
##
##   delta = inverse(source_rest_rotation) * source_animated_rotation
##   nwn_rotation = nwn_rest_rotation * delta
##
## i.e. "whatever rotation change happened relative to the source's own bind
## pose, apply that same relative change on top of NWN's own bind pose."
##
## The rest reference is just the SAME imported file's Skeleton3D.get_bone_rest()
## (a skeleton's own bind pose is intrinsic to it, independent of whatever
## animation is currently posed) — no separate "reference" glb is needed.
class_name Retargeter

static func _load_glb(path: String) -> Node3D:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(path, state)
	if err != OK:
		return null
	return doc.generate_scene(state) as Node3D

static func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null

static func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found := _find_animation_player(child)
		if found != null:
			return found
	return null

## Returns {"keyframes": Array, "length": float, "anim_name": String} on
## success, or {"error": String} on failure. `parent` must already be in the
## running scene tree — the imported AnimationPlayer needs that to resolve
## its track NodePaths down to the Skeleton3D.
## rotation_offsets: optional {nwn_node_name: Vector3 (degrees)} — a per-bone
## local-frame rotation tweak, applied after the retarget delta, for fixing
## axis mismatches one joint at a time instead of one global knob.
static func bake(parent: Node, anim_glb_path: String, bone_map: Dictionary, nwn_rest_transforms_by_name: Dictionary, source_fps: float, root_scale: float, rotation_offsets: Dictionary = {}) -> Dictionary:
	var anim_scene := _load_glb(anim_glb_path)
	if anim_scene == null:
		return {"error": "Could not load animation source: %s" % anim_glb_path}
	parent.add_child(anim_scene)

	var anim_skeleton := _find_skeleton(anim_scene)
	var anim_player := _find_animation_player(anim_scene)
	if anim_skeleton == null or anim_player == null:
		anim_scene.queue_free()
		return {"error": "The animation source needs both a Skeleton3D and an AnimationPlayer."}

	var anim_names := anim_player.get_animation_list()
	if anim_names.is_empty():
		anim_scene.queue_free()
		return {"error": "No animations found in the imported file."}
	var anim_name: String = anim_names[0]
	var animation: Animation = anim_player.get_animation(anim_name)
	var length: float = animation.length

	var rest_rotations := {}
	for i in range(anim_skeleton.get_bone_count()):
		rest_rotations[anim_skeleton.get_bone_name(i)] = anim_skeleton.get_bone_rest(i).basis.get_rotation_quaternion()

	var root_source_bone: String = bone_map.get("rootdummy", "")
	var rest_root_pos := Vector3.ZERO
	if root_source_bone != "":
		var root_bone_idx: int = anim_skeleton.find_bone(root_source_bone)
		if root_bone_idx >= 0:
			rest_root_pos = anim_skeleton.get_bone_rest(root_bone_idx).origin

	anim_player.play(anim_name)

	var total_frames: int = max(1, int(round(length * source_fps)))
	var keyframes: Array = []
	for frame_i in range(total_frames + 1):
		var t: float = min(frame_i / source_fps, length)
		anim_player.seek(t, true)

		var transforms: Dictionary = nwn_rest_transforms_by_name.duplicate()
		for nwn_node_name in bone_map.keys():
			var source_bone_name: String = bone_map[nwn_node_name]
			if source_bone_name == "" or not nwn_rest_transforms_by_name.has(nwn_node_name):
				continue
			var bone_idx: int = anim_skeleton.find_bone(source_bone_name)
			if bone_idx < 0:
				continue

			var animated_rot: Quaternion = anim_skeleton.get_bone_pose_rotation(bone_idx)
			var rest_rot: Quaternion = rest_rotations.get(source_bone_name, Quaternion.IDENTITY)
			var delta: Quaternion = rest_rot.inverse() * animated_rot

			var nwn_rest_transform: Transform3D = nwn_rest_transforms_by_name[nwn_node_name]
			var target_rot: Quaternion = nwn_rest_transform.basis.get_rotation_quaternion() * delta
			var origin: Vector3 = nwn_rest_transform.origin

			var offset_deg: Vector3 = rotation_offsets.get(nwn_node_name, Vector3.ZERO)
			if offset_deg != Vector3.ZERO:
				var offset_quat := Quaternion.from_euler(Vector3(
					deg_to_rad(offset_deg.x), deg_to_rad(offset_deg.y), deg_to_rad(offset_deg.z)
				))
				target_rot = target_rot * offset_quat # intrinsic: rotate around the bone's own local axes

			if nwn_node_name == "rootdummy":
				var animated_pos: Vector3 = anim_skeleton.get_bone_pose_position(bone_idx)
				origin = nwn_rest_transform.origin + (animated_pos - rest_root_pos) * root_scale

			transforms[nwn_node_name] = Transform3D(Basis(target_rot), origin)

		keyframes.append({"time": t, "transforms": transforms})
		if t >= length:
			break

	anim_player.stop()
	anim_scene.queue_free()

	return {"keyframes": keyframes, "length": length, "anim_name": anim_name}
