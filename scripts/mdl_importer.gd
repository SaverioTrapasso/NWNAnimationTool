## Parses a NWN MDL ASCII newanim/doneanim block (as produced by MdlExporter)
## back into an animation name, length, and a list of keyframes that can be
## applied to the rig or loaded onto the timeline.
class_name MdlImporter

## Returns {"anim_name": String, "length": float, "keyframes": Array} or
## null if the text couldn't be parsed (e.g. no "newanim" line found).
## Each keyframe is {"time": float, "transforms": {node_name: Transform3D}}.
static func parse(text: String, rig_root: Node3D) -> Variant:
	var anim_name := ""
	var length := 1.0
	var position_data := {} # node_name -> Array[Array[float]] (time, x, y, z)
	var orientation_data := {} # node_name -> Array[Array[float]] (time, x, y, z, angle)

	var current_node_name := ""
	var reading_mode := "" # "", "position", "orientation"
	var found_newanim := false

	for raw_line in text.split("\n"):
		var line := raw_line.strip_edges()
		if line.begins_with("newanim "):
			var parts := line.split(" ", false)
			if parts.size() >= 2:
				anim_name = parts[1]
				found_newanim = true
		elif line.begins_with("length "):
			var parts := line.split(" ", false)
			if parts.size() >= 2:
				length = parts[1].to_float()
		elif line.begins_with("node "):
			var parts := line.split(" ", false)
			if parts.size() >= 3:
				current_node_name = parts[2]
		elif line == "positionkey":
			reading_mode = "position"
		elif line == "orientationkey":
			reading_mode = "orientation"
		elif line == "endlist":
			reading_mode = ""
		elif line == "endnode":
			current_node_name = ""
		elif current_node_name != "" and reading_mode != "":
			var nums := line.split(" ", false)
			if reading_mode == "position" and nums.size() >= 4:
				if not position_data.has(current_node_name):
					position_data[current_node_name] = []
				position_data[current_node_name].append(_to_floats(nums))
			elif reading_mode == "orientation" and nums.size() >= 5:
				if not orientation_data.has(current_node_name):
					orientation_data[current_node_name] = []
				orientation_data[current_node_name].append(_to_floats(nums))

	if not found_newanim:
		return null

	var times := {}
	for node_name in orientation_data.keys():
		for entry in orientation_data[node_name]:
			times[entry[0]] = true
	var sorted_times: Array = times.keys()
	sorted_times.sort()
	if sorted_times.is_empty():
		sorted_times = [0.0]

	var keyframes: Array = []
	for t in sorted_times:
		var transforms: Dictionary = MdlExporter.capture_pose(rig_root)
		for node_name in orientation_data.keys():
			var entry: Variant = _find_entry_at_time(orientation_data[node_name], t)
			if entry == null or not transforms.has(node_name):
				continue
			var axis := MdlExporter._from_nwn_space(Vector3(entry[1], entry[2], entry[3]))
			var angle: float = entry[4]
			var basis := Basis()
			if angle > 0.0001 and axis.length() > 0.0001:
				basis = Basis(axis.normalized(), angle)
			var old_origin: Vector3 = transforms[node_name].origin
			transforms[node_name] = Transform3D(basis, old_origin)
		if position_data.has("rootdummy") and transforms.has("rootdummy"):
			var pentry: Variant = _find_entry_at_time(position_data["rootdummy"], t)
			if pentry != null:
				var pos := MdlExporter._from_nwn_space(Vector3(pentry[1], pentry[2], pentry[3]))
				transforms["rootdummy"] = Transform3D(transforms["rootdummy"].basis, pos)
		keyframes.append({"time": t, "transforms": transforms})

	return {"anim_name": anim_name, "length": length, "keyframes": keyframes}

static func _to_floats(parts: PackedStringArray) -> Array:
	var out: Array = []
	for p in parts:
		out.append(p.to_float())
	return out

static func _find_entry_at_time(entries: Array, t: float) -> Variant:
	for entry in entries:
		if abs(entry[0] - t) < 0.0001:
			return entry
	return null
