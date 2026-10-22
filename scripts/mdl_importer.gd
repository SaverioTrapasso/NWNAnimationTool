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
		var line := raw_line.replace("\t", " ").strip_edges()
		if line.begins_with("newanim "):
			if found_newanim: return null # Full banks must select one clip first.
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
				# Aurora node names are case-insensitive (stock models use Lbicep_g).
				current_node_name = parts[2].to_lower()
		elif current_node_name != "" and line.begins_with("position "):
			position_data[current_node_name] = [[0.0] + _to_floats(line.split(" ", false).slice(1))]
			reading_mode = ""
		elif current_node_name != "" and line.begins_with("orientation "):
			orientation_data[current_node_name] = [[0.0] + _to_floats(line.split(" ", false).slice(1))]
			reading_mode = ""
		elif line == "positionkey" or line.begins_with("positionkey "):
			reading_mode = "position"
		elif line == "orientationkey" or line.begins_with("orientationkey "):
			reading_mode = "orientation"
		elif line == "endlist":
			reading_mode = ""
		elif line == "endnode":
			current_node_name = ""
			reading_mode = ""
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

	if not found_newanim or (orientation_data.is_empty() and position_data.is_empty()):
		return null

	var times := {}
	for node_name in orientation_data.keys():
		for entry in orientation_data[node_name]:
			times[entry[0]] = true
	for node_name in position_data.keys():
		for entry in position_data[node_name]:
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
			if abs(angle) > 0.0001 and axis.length() > 0.0001:
				basis = Basis(axis.normalized(), angle)
			var old_origin: Vector3 = transforms[node_name].origin
			transforms[node_name] = Transform3D(basis, old_origin)
		for node_name in position_data:
			if not transforms.has(node_name): continue
			var pentry: Variant = _find_entry_at_time(position_data[node_name], t)
			if pentry != null:
				var pos := MdlExporter._from_nwn_space(Vector3(pentry[1], pentry[2], pentry[3]))
				transforms[node_name] = Transform3D(transforms[node_name].basis, pos)
		keyframes.append({"time": t, "transforms": transforms})

	return {"anim_name": anim_name, "length": length, "keyframes": keyframes}

static func _to_floats(parts: PackedStringArray) -> Array:
	var out: Array = []
	for p in parts:
		out.append(p.to_float())
	return out

static func _find_entry_at_time(entries: Array, t: float) -> Variant:
	if entries.is_empty():return null
	if t<=entries[0][0]:return entries[0]
	for i in range(entries.size()-1):
		var lo=entries[i];var hi=entries[i+1]
		if t>hi[0]:continue
		var f=(t-lo[0])/(hi[0]-lo[0])
		if lo.size()==4:
			return [t,lerp(lo[1],hi[1],f),lerp(lo[2],hi[2],f),lerp(lo[3],hi[3],f)]
		var ax=Vector3(lo[1],lo[2],lo[3]);var bx=Vector3(hi[1],hi[2],hi[3])
		var qa=Quaternion(ax.normalized(),lo[4]) if ax.length()>.00001 else Quaternion.IDENTITY
		var qb=Quaternion(bx.normalized(),hi[4]) if bx.length()>.00001 else Quaternion.IDENTITY
		var q=qa.slerp(qb,f).normalized();var axis=q.get_axis()
		return [t,axis.x,axis.y,axis.z,q.get_angle()]
	return entries[-1]
