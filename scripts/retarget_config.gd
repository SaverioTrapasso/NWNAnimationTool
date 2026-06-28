## Loads/saves a retargeting config (.cfg): the source's frame rate, root
## motion scale, and the NWN-node -> source-bone name mapping.
##
## Deliberately has no reference to any specific glb file — both the
## animation source and the rest-pose reference are the SAME imported file
## at bake time (a Skeleton3D's own get_bone_rest() is already its bind
## pose, so no separate "reference" asset needs to be bundled or pinned).
## That's what makes the config portable: load whichever .cfg you want,
## then import whatever glb matches that bone naming.
##
## No per-bone rotation offset is stored here anymore — Bake derives the
## correction live from however you've hand-posed the rig to match the
## overlay at the moment you press it, instead of a typed/saved number.
##
## Plain text, hand-editable — and also editable live from the bone-map
## panel, which writes back through save_to_file().
class_name RetargetConfig

## The fixed set of NWN nodes the bone-map table always shows, regardless of
## whether a .cfg is loaded yet — only the *values* (associated bone) come
## from the config; the row list itself doesn't.
const NWN_NODES := [
	"rootdummy", "pelvis_g", "torso_g", "neck_g", "head_g",
	"rbicep_g", "rforearm_g", "rhand_g",
	"lbicep_g", "lforearm_g", "lhand_g",
	"rthigh_g", "rshin_g", "rfoot_g",
	"lthigh_g", "lshin_g", "lfoot_g",
]

static func load_from_file(path: String) -> Dictionary:
	var cf := ConfigFile.new()
	var err := cf.load(path)
	if err != OK:
		return {}

	var bone_map := {}
	if cf.has_section("bone_map"):
		for key in cf.get_section_keys("bone_map"):
			var v = cf.get_value("bone_map", key, "")
			if String(v) != "":
				bone_map[key] = String(v)

	return {
		"prefab_name": String(cf.get_value("meta", "prefab_name", "")),
		"source_fps": float(cf.get_value("meta", "source_fps", 30.0)),
		"root_scale": float(cf.get_value("meta", "root_scale", 1.0)),
		"bone_map": bone_map,
	}

## Rewrites the config file with the given bone_map, while preserving any
## leading "; ..." comment block from the existing file (the explanatory
## notes about the rig) so live edits from the UI don't wipe them.
static func save_to_file(path: String, prefab_name: String, source_fps: float, root_scale: float, bone_map: Dictionary) -> Error:
	var header := ""
	if FileAccess.file_exists(path):
		var existing := FileAccess.open(path, FileAccess.READ)
		if existing != null:
			while not existing.eof_reached():
				var line := existing.get_line()
				if line.strip_edges().begins_with(";") or line.strip_edges() == "":
					header += line + "\n"
				else:
					break
			existing.close()

	var lines: PackedStringArray = []
	if header != "":
		lines.append(header.strip_edges(false, true))
	lines.append("")
	lines.append("[meta]")
	lines.append("prefab_name = \"%s\"" % prefab_name)
	lines.append("source_fps = %s" % str(source_fps))
	lines.append("root_scale = %s" % str(root_scale))
	lines.append("")
	lines.append("[bone_map]")
	for key in bone_map.keys():
		lines.append("%s = \"%s\"" % [key, bone_map[key]])

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string("\n".join(lines) + "\n")
	file.close()
	return OK
