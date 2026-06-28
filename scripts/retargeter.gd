## Bakes an animation from a foreign skeleton onto the NWN rig using a
## Maya-style "orient constraint with maintain offset" model:
##
## At "Lock" time, for every mapped NWN node we record a fixed WORLD-SPACE
## offset between the source bone's current world rotation and the NWN
## node's current (hand-posed) world rotation:
##
##   offset = inverse(source_world_rotation_at_lock) * nwn_world_rotation_at_lock
##
## Then for every frame of the bake:
##
##   nwn_world_rotation(t) = source_world_rotation(t) * offset
##
## i.e. the NWN node rigidly follows the source bone's world rotation, plus
## that same fixed offset, exactly like a Maya constraint. This works in
## WORLD space, so unlike a per-bone LOCAL delta scheme, it's not sensitive
## to how extreme the source rig's own bind pose is — there's no rest-pose
## reference involved at all, just "the source bone's current orientation,
## offset by a constant." Each NWN node's LOCAL (parent-relative) rotation —
## the only thing the MDL format actually stores — is then recovered by
## dividing out its NWN parent's world rotation, walked top-down through the
## fixed hierarchy (MdlExporter.flatten_skeleton_tree()), exactly as nested
## constraints would cascade in Maya.
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

## A bone's world rotation/position, including the Skeleton3D node's OWN
## external transform (e.g. a "Flip 180°" rotation applied to the loaded
## scene). get_bone_global_pose() alone is relative to the Skeleton3D node
## itself and completely ignores how that node is placed in the scene, so a
## root-level flip would otherwise have zero effect on the retargeting math
## — multiplying by skeleton.global_transform is what makes it real.
static func _source_world_rot(anim_skeleton: Skeleton3D, bone_idx: int) -> Quaternion:
	return (anim_skeleton.global_transform.basis * anim_skeleton.get_bone_global_pose(bone_idx).basis).get_rotation_quaternion()

static func _source_world_pos(anim_skeleton: Skeleton3D, bone_idx: int) -> Vector3:
	return anim_skeleton.global_transform * anim_skeleton.get_bone_global_pose(bone_idx).origin

## "Lock": call once, right after seeking the source skeleton to the frame
## you hand-posed the rig against. Captures, for every mapped NWN node, the
## fixed world-space offset between the source bone's current world
## rotation and the NWN node's current (real $Rig, hand-posed) world
## rotation — and for rootdummy specifically, the world positions needed to
## drive root motion the same way root_scale always has.
## nwn_world_rotations_by_name/nwn_world_positions_by_name: the REAL rig's
## CURRENT global rotation/position for every node (whatever you posed it
## to, by hand, to match the overlay).
static func lock_offsets(anim_skeleton: Skeleton3D, bone_map: Dictionary, nwn_world_rotations_by_name: Dictionary, nwn_world_positions_by_name: Dictionary) -> Dictionary:
	var offsets := {}
	for nwn_node_name in bone_map.keys():
		var source_bone_name: String = bone_map[nwn_node_name]
		if source_bone_name == "" or not nwn_world_rotations_by_name.has(nwn_node_name):
			continue
		var bone_idx: int = anim_skeleton.find_bone(source_bone_name)
		if bone_idx < 0:
			continue
		var source_world_rot: Quaternion = _source_world_rot(anim_skeleton, bone_idx)
		var nwn_world_rot: Quaternion = nwn_world_rotations_by_name[nwn_node_name]
		offsets[nwn_node_name] = source_world_rot.inverse() * nwn_world_rot

	var root_match := {}
	if nwn_world_positions_by_name.has("rootdummy"):
		# Always remember where rootdummy was at lock time, even if it isn't
		# mapped (or its source bone can't be found) -- that way bake() can
		# freeze it there instead of silently reverting to the import-time
		# rest pose, which previously produced an unexplained height jump.
		root_match["target_pos"] = nwn_world_positions_by_name["rootdummy"]
		var root_source_bone: String = bone_map.get("rootdummy", "")
		if root_source_bone != "":
			var root_idx: int = anim_skeleton.find_bone(root_source_bone)
			if root_idx >= 0:
				root_match["source_pos"] = _source_world_pos(anim_skeleton, root_idx)

	return {"offsets": offsets, "root_match": root_match}

## Computes every NWN node's LOCAL transform for whatever pose anim_skeleton
## is CURRENTLY in (caller seeks the AnimationPlayer first), by walking the
## fixed hierarchy top-down: each mapped node's world rotation comes from
## the constraint (source world rotation * locked offset); each unmapped
## node just keeps its rest local rotation; either way, the LOCAL rotation
## written out is recovered by dividing out the already-computed parent
## world rotation, so children of a "flipped" parent come out correctly
## oriented in world space too.
static func sample_pose(anim_skeleton: Skeleton3D, hierarchy: Array, bone_map: Dictionary, nwn_rest_transforms_by_name: Dictionary, lock_data: Dictionary, root_scale: float) -> Dictionary:
	var offsets: Dictionary = lock_data.get("offsets", {})
	var root_match: Dictionary = lock_data.get("root_match", {})

	var world_rotations := {} # node_name -> Quaternion, accumulated top-down
	var transforms := {}

	for entry in hierarchy:
		var name: String = entry["name"]
		var parent_name: String = entry["parent"]
		var parent_world_rot: Quaternion = world_rotations.get(parent_name, Quaternion.IDENTITY)

		var rest_transform: Transform3D = nwn_rest_transforms_by_name.get(name, Transform3D())
		var origin: Vector3 = rest_transform.origin
		var world_rot: Quaternion
		var local_rot: Quaternion

		var source_bone_name: String = bone_map.get(name, "")
		var bone_idx: int = anim_skeleton.find_bone(source_bone_name) if source_bone_name != "" else -1

		if bone_idx >= 0 and offsets.has(name):
			var source_world_rot: Quaternion = _source_world_rot(anim_skeleton, bone_idx)
			world_rot = source_world_rot * offsets[name]
			local_rot = parent_world_rot.inverse() * world_rot

			if name == "rootdummy" and root_match.has("target_pos"):
				if root_match.has("source_pos"):
					# anim_skeleton's own transform already carries root_scale
					# (bake() applies it to match the overlay lock_offsets()
					# read from), so this delta is already in scaled space --
					# multiplying by root_scale again here would double it.
					var source_world_pos: Vector3 = _source_world_pos(anim_skeleton, bone_idx)
					origin = root_match["target_pos"] + (source_world_pos - root_match["source_pos"])
				else:
					origin = root_match["target_pos"]
		else:
			local_rot = rest_transform.basis.get_rotation_quaternion()
			world_rot = parent_world_rot * local_rot
			# rootdummy isn't mapped (or its source bone can't be resolved):
			# freeze it at the locked, hand-posed position instead of
			# reverting to the import-time rest pose.
			if name == "rootdummy" and root_match.has("target_pos"):
				origin = root_match["target_pos"]

		world_rotations[name] = world_rot
		transforms[name] = Transform3D(Basis(local_rot), origin)

	return transforms

## Returns {"keyframes": Array, "length": float, "anim_name": String} on
## success, or {"error": String} on failure. `parent` must already be in the
## running scene tree — the imported AnimationPlayer needs that to resolve
## its track NodePaths down to the Skeleton3D. `lock_data` comes from
## lock_offsets(), captured at whatever frame you hand-posed the rig against.
## `flip_180` must match whatever the source overlay had set when Lock was
## pressed — bake() reloads the glb fresh, so it has to re-apply the exact
## same external rotation for the world-space math to stay consistent with
## what was captured at Lock time.
static func bake(parent: Node, anim_glb_path: String, bone_map: Dictionary, nwn_rest_transforms_by_name: Dictionary, source_fps: float, root_scale: float, lock_data: Dictionary, flip_180: bool = false) -> Dictionary:
	var anim_scene := _load_glb(anim_glb_path)
	if anim_scene == null:
		return {"error": "Could not load animation source: %s" % anim_glb_path}
	parent.add_child(anim_scene)
	if flip_180:
		anim_scene.rotation.y = PI
	# Match the live overlay's scale (set via the Root Scale slider) so this
	# freshly-reloaded copy reads the exact same world-space positions that
	# lock_offsets() captured from the overlay -- otherwise the locked frame
	# itself wouldn't line up and root_scale != 1.0 would break continuity.
	anim_scene.scale = Vector3.ONE * root_scale

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

	var hierarchy: Array = MdlExporter.flatten_skeleton_tree()

	anim_player.play(anim_name)

	var total_frames: int = max(1, int(round(length * source_fps)))
	var keyframes: Array = []
	for frame_i in range(total_frames + 1):
		var t: float = min(frame_i / source_fps, length)
		anim_player.seek(t, true)
		var transforms := sample_pose(anim_skeleton, hierarchy, bone_map, nwn_rest_transforms_by_name, lock_data, root_scale)
		keyframes.append({"time": t, "transforms": transforms})
		if t >= length:
			break

	anim_player.stop()
	anim_scene.queue_free()

	return {"keyframes": keyframes, "length": length, "anim_name": anim_name}
