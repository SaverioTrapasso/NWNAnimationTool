extends RefCounted

# Local game data only; no game geometry is bundled with the application.
static func build(double_staff: bool = true) -> MeshInstance3D:
	var path := "user://saberstaff/saberstaff.json" if double_staff else "user://lightsaber/lightsaber.json"
	return build_file(path)

static func build_file(path: String) -> MeshInstance3D:
	if not FileAccess.file_exists(path): return null
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not data is Dictionary or not data.has("nodes"): return null
	var transforms := {}
	var mesh := ArrayMesh.new()
	var emitters: Array[MeshInstance3D] = []
	for entry in data.nodes:
		var props: Dictionary = entry[2]
		var transform := Transform3D.IDENTITY
		if props.has("position"): transform.origin = _vector(props.position)
		if props.has("orientation"):
			var axis := _vector(props.orientation)
			if axis.length() > .00001: transform.basis = Basis(axis.normalized(),float(props.orientation[3]))
		if props.has("scale"): transform.basis = transform.basis.scaled(Vector3.ONE * float(props.scale[0]))
		var parent: String = str(props.get("parent",["null"])[0]).to_lower()
		transform = transforms.get(parent,Transform3D.IDENTITY) * transform
		transforms[str(entry[1]).to_lower()] = transform
		if entry[0] == "emitter":
			var emitter := _emitter(props,transform,path.get_base_dir())
			if emitter != null: emitters.append(emitter)
		if props.get("render",["1"])[0] == "0": continue
		if not props.has("verts") or not props.has("faces"): continue
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for face in props.faces:
			for i in [0,2,1]:
				if props.has("tverts") and face.size() >= 7:
					var uv = props.tverts[int(face[4+i])]
					st.set_uv(Vector2(float(uv[0]),1.0-float(uv[1])))
				st.add_vertex(transform * _vector(props.verts[int(face[i])]))
		st.generate_normals()
		var material := StandardMaterial3D.new()
		material.albedo_color = Color.WHITE
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		var texture_path := path.get_base_dir().path_join(str(props.get("bitmap",[""])[0]).to_lower()+".png")
		if FileAccess.file_exists(texture_path):
			var img := Image.load_from_file(ProjectSettings.globalize_path(texture_path))
			if img != null: material.albedo_texture = ImageTexture.create_from_image(img)
		st.set_material(material)
		st.commit(mesh)
	if mesh.get_surface_count() == 0 and emitters.is_empty(): return null
	var result := MeshInstance3D.new()
	result.name = "GameSaberstaff"
	result.mesh = mesh
	result.set_meta("game_resource",data.get("resource",""))
	# Preserve original MDL attachment, hierarchy transforms, and emitter placement.
	for emitter in emitters: result.add_child(emitter)
	result.set_meta("emitter_count",emitters.size())
	return result

static func _vector(values: Array) -> Vector3:
	return Vector3(float(values[0]),float(values[2]),-float(values[1]))

static func _emitter(props: Dictionary, transform: Transform3D, directory: String) -> MeshInstance3D:
	var texture_path := directory.path_join(str(props.get("texture",[""])[0]).to_lower()+".png")
	if not FileAccess.file_exists(texture_path): return null
	var img := Image.load_from_file(ProjectSettings.globalize_path(texture_path))
	if img == null: return null
	var result := MeshInstance3D.new()
	result.name = "GameEmitter"
	var quad := QuadMesh.new()
	quad.size = Vector2(float(props.get("sizestart",["1"])[0]),float(props.get("sizestart_y",props.get("sizestart",["1"]))[0]))
	result.mesh = quad
	# NWN emitter cards lie in local XY; convert this plane to Godot coordinates.
	result.transform = transform * Transform3D(Basis(Vector3.RIGHT,-PI/2),Vector3.ZERO)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_texture = ImageTexture.create_from_image(img)
	result.material_override = material
	return result

static func apply_hands(rig: Node3D, female: bool) -> void:
	for side in ["l","r"]:
		var resource: String = ("pfh0" if female else "pmh0") + "_hand" + side + "008"
		var source := build_file("user://hands008/" + resource + ".json")
		if source == null: continue
		var hand := rig.find_child(side + "hand_g",true,false) as MeshInstance3D
		if hand != null:
			hand.mesh = source.mesh
			hand.set_meta("hand_resource",resource)
		source.free()
