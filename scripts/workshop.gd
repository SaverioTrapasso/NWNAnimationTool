extends Node

# Editor helpers are separate from the exported skeleton and animation tracks.
var app: Node3D
var dirty := false
var elapsed := 0.0
var autosave_path := "user://workshop-recovery.nwap"
var pins: Dictionary = {}
var detach_right_hand := false
var right_weapon_transform := Transform3D.IDENTITY
var grip := false
var grip_offset := Transform3D.IDENTITY
var controls: Dictionary = {}
var panel: AcceptDialog
var guides: Node3D
var trail: MeshInstance3D
var trail_points: Array[Vector3] = []
var trail_enabled := false
var last_time := -1.0
var browser: AcceptDialog
var entries: ItemList
var folder: OptionButton
var search: LineEdit
var library: Array = []
var library_memory_slot: int = -1
var custom_pose_folders: Array[String] = []
var library_config_path := "user://pose-library.cfg"
var pose_folder_dialog: FileDialog
var library_status: Label
var thumb_world: Dictionary
var thumb_busy := false
var thumb_generation := 0
var comparison: Window
var views: Array = []
var reference: Dictionary = {}
var normalize_time := true
var key_list: ItemList
var key_name: LineEdit
var key_time: SpinBox
var file_dialog: FileDialog
var project_save := false
var thumbnail_cache: Dictionary = {}

func _ready() -> void:
	app = get_parent()
	process_priority = 100
	var button := Button.new()
	button.text = "Workshop"
	button.tooltip_text = "Undo / recovery, target, blade trail, hand and foot locks, pose library and comparison"
	app.side_panel.viewport_toolbar.add_child(button)
	button.pressed.connect(func(): panel.popup_centered(Vector2i(610, 650)))
	_build_panel()
	_build_guides()
	_build_library()
	file_dialog = FileDialog.new()
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.filters = PackedStringArray(["*.nwap ; Animation workshop project"])
	app.add_child(file_dialog)
	file_dialog.file_selected.connect(_project_file)
	if FileAccess.file_exists(autosave_path):
		app.side_panel.set_status("Recovery available: Workshop > Recover autosave.")

func _button(parent: Node, text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	parent.add_child(b)
	b.pressed.connect(action)
	return b

func _check(parent: Node, text: String, action: Callable) -> CheckButton:
	var b := CheckButton.new()
	b.text = text
	parent.add_child(b)
	b.toggled.connect(action)
	return b

func _label(parent: Node, text: String) -> void:
	var l := Label.new()
	l.text = text
	parent.add_child(l)

func _build_panel() -> void:
	panel = AcceptDialog.new()
	panel.title = "Animation Workshop"
	app.add_child(panel)
	var scroll := ScrollContainer.new()
	panel.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	_label(box, "Safety — autosave every 30 seconds after edits")
	var row := HBoxContainer.new()
	box.add_child(row)
	_button(row, "Undo", app._undo)
	_button(row, "Redo", app._redo)
	_button(row, "Recover autosave", func(): _load_project(autosave_path))
	row = HBoxContainer.new()
	box.add_child(row)
	_button(row, "Save project...", func(): _project_dialog(true))
	_button(row, "Open project...", func(): _project_dialog(false))
	_button(box, "Settings / local folders...", func(): WorkshopSettings.show_dialog(app))
	_button(box, "Import NWN1 reference library...", func(): app.mdl_bank.import_references())
	_build_quick_toolbar()
	_button(box, "Add pose folder...", _choose_pose_folder)
	_button(box, "Pose library / NWN1 references / Compare...", func():
		open_library())
	_label(box, "Keyframes — select a key, name it or change its time")
	key_list = ItemList.new()
	key_list.custom_minimum_size = Vector2(480, 130)
	box.add_child(key_list)
	key_list.item_selected.connect(_select_key)
	row = HBoxContainer.new()
	box.add_child(row)
	key_name = LineEdit.new()
	key_name.placeholder_text = "Guard / Preparation / Strike / Return"
	key_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(key_name)
	key_time = SpinBox.new()
	key_time.min_value = 0
	key_time.max_value = 600
	key_time.step = .01
	row.add_child(key_time)
	_button(row, "Apply", _edit_key)
	row = HBoxContainer.new()
	box.add_child(row)
	for title in ["Guard", "Preparation", "Strike", "Return"]:
		_button(row, title, func(): key_name.text = title; _edit_key())
	_label(box, "Timeline: drag a dot to move one key; Shift+drag moves following keys.")
	_label(box, "Changing Duration scales all key times. Project files retain key names.")
	panel.about_to_popup.connect(refresh_keys)

func _quick_toggle(parent: Node, text: String, tip: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.toggle_mode = true
	parent.add_child(b)
	b.toggled.connect(action)
	return b

func _build_quick_toolbar() -> void:
	var bar := HFlowContainer.new()
	bar.name = "PoseToolsToolbar"
	app.side_panel.add_child(bar)
	bar.anchor_right = 1.0
	bar.offset_left = 200.0
	bar.offset_right = -8.0
	bar.offset_top = 60.0
	bar.offset_bottom = 90.0
	bar.alignment = FlowContainer.ALIGNMENT_CENTER
	bar.mouse_filter = Control.MOUSE_FILTER_PASS
	var hilt := _quick_toggle(bar, "Hilt", "Show lightsaber hilt (preview only)", app.side_panel._on_hilt_toggled)
	hilt.set_pressed_no_signal(app.side_panel._show_hilt)
	_quick_toggle(bar, "Target", "Show forward axis and target dummy (preview only)", func(v): guides.visible = v)
	_quick_toggle(bar, "Trail", "Show blade-tip trail (preview only)", func(v): trail_enabled = v; clear_trail())
	_button(bar, "Clear trail", clear_trail)
	controls.detach_right_hand = _quick_toggle(bar, "Free R hand", "Detach right hand from weapon. Set a key after editing; playback uses saved keys.", _set_detach_right_hand)
	_button(bar, "T-pose", app._set_t_pose).tooltip_text = "Set T-pose without replacing animation keys. Ctrl+Z to undo."
	controls.grip = _quick_toggle(bar, "L grip", "Keep left hand on right-hand grip while editing. Set a key after editing.", _set_grip)
	controls.left_leg = _quick_toggle(bar, "Pin L foot", "Pin left foot while editing. Set a key after editing.", func(v): _pin("left_leg", v))
	controls.right_leg = _quick_toggle(bar, "Pin R foot", "Pin right foot while editing. Set a key after editing.", func(v): _pin("right_leg", v))

func refresh_keys() -> void:
	key_list.clear()
	for k in app._keyframes:
		key_list.add_item("%.3f s   %s" % [k.time, k.get("label", "Key")])

func _select_key(index: int) -> void:
	if index >= app._keyframes.size(): return
	var k: Dictionary = app._keyframes[index]
	key_name.text = k.get("label", "")
	key_time.set_value_no_signal(k.time)
	app._on_timeline_scrubbed(k.time)
	app.side_panel.timeline.set_current_time(k.time)

func _edit_key() -> void:
	var selected := key_list.get_selected_items()
	if selected.is_empty() or selected[0] >= app._keyframes.size(): return
	var index := selected[0]
	var t := clampf(key_time.value, 0, app._anim_length)
	for i in range(app._keyframes.size()):
		if i != index and absf(app._keyframes[i].time - t) < .001:
			app.side_panel.set_status("Another key already exists at that time.")
			return
	app._push_undo_snapshot()
	app._keyframes[index]["time"] = t
	app._keyframes[index]["label"] = key_name.text
	app._keyframes.sort_custom(func(a, b): return a.time < b.time)
	app._refresh_timeline_markers()
	refresh_keys()

func _project_dialog(save: bool) -> void:
	project_save = save
	file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE if save else FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.current_file = "animation.nwap" if save else ""
	file_dialog.popup_centered_ratio(.75)

func _project_file(path: String) -> void:
	if project_save:
		if path.get_extension().is_empty(): path += ".nwap"
		if _write_project(path): app.side_panel.set_status("Project saved: " + path)
	else: _load_project(path)

func _write_project(path: String) -> bool:
	var temp := path + ".tmp"
	var f := FileAccess.open(temp, FileAccess.WRITE)
	if f == null:
		app.side_panel.set_status("Cannot save project: " + error_string(FileAccess.get_open_error()))
		return false
	f.store_var({"version": 1, "document": app._document_state()})
	f.flush()
	var err := f.get_error()
	f.close()
	if err == OK: err = DirAccess.rename_absolute(temp, path)
	if err != OK: app.side_panel.set_status("Project save failed: " + error_string(err))
	return err == OK

func _load_project(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return
	var data: Variant = f.get_var(false)
	if not data is Dictionary or data.get("version") != 1 or not data.get("document") is Dictionary:
		app.side_panel.set_status("Invalid workshop project.")
		return
	var doc: Dictionary = data.document
	if not doc.get("keys") is Array or not doc.get("pose") is Dictionary or not doc.has_all(["length", "time", "name"]):
		app.side_panel.set_status("Incomplete workshop project.")
		return
	app._push_undo_snapshot()
	app._restore_document(doc)
	refresh_keys()
	app.side_panel.set_status("Recovered / opened project: " + path)

func _set_detach_right_hand(enabled: bool) -> void:
	detach_right_hand = enabled
	if enabled:
		var weapon: Node3D = app.rig_controller.find_node("rhand")
		right_weapon_transform = weapon.global_transform

func _set_grip(enabled: bool) -> void:
	grip = enabled
	if enabled:
		var right: Node3D = app.rig_controller.find_node("rhand")
		var left: Node3D = app.rig_controller.find_node("lhand_g")
		grip_offset = right.global_transform.affine_inverse() * left.global_transform

func _pin(id: String, enabled: bool) -> void:
	if not enabled: pins.erase(id); return
	var chain: Array = app.rig_controller.get_chain_nodes(id)
	if chain.size() == 3:
		pins[id] = {"transform": chain[2].global_transform, "pole": app._limb_targets[id].pole}

func release_constraints() -> void:
	detach_right_hand = false
	grip = false
	pins.clear()
	for c in controls.values(): c.set_pressed_no_signal(false)
	clear_trail()

func apply_constraints() -> void:
	if detach_right_hand:
		var weapon: Node3D = app.rig_controller.find_node("rhand")
		weapon.global_transform = right_weapon_transform
	for id in pins:
		var chain: Array = app.rig_controller.get_chain_nodes(id)
		var p: Dictionary = pins[id]
		IKSolver.solve_two_bone(chain[0], chain[1], chain[2], p.transform.origin, p.pole)
		chain[2].global_basis = p.transform.basis
		app._limb_targets[id].target = p.transform.origin
		app._limb_targets[id].end_basis = p.transform.basis
	if grip:
		var right: Node3D = app.rig_controller.find_node("rhand")
		var target: Transform3D = right.global_transform * grip_offset
		var chain: Array = app.rig_controller.get_chain_nodes("left_arm")
		var pole: Vector3 = app._limb_targets.left_arm.pole
		IKSolver.solve_two_bone(chain[0], chain[1], chain[2], target.origin, pole)
		chain[2].global_basis = target.basis
		app._limb_targets.left_arm.target = target.origin
		app._limb_targets.left_arm.end_basis = target.basis

func _process(delta: float) -> void:
	if not app._playing: apply_constraints()
	elapsed += delta
	if elapsed >= 30:
		elapsed = 0
		if dirty and _write_project(autosave_path): dirty = false
	_update_trail()
	if comparison != null and comparison.visible: _update_comparison()

func _mesh(parent: Node3D, mesh: Mesh, pos: Vector3, color: Color) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position = pos
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	instance.material_override = material
	parent.add_child(instance)
	return instance

func _build_guides() -> void:
	guides = Node3D.new()
	guides.name = "EditorTargetGuide"
	app.add_child(guides)
	guides.visible = false
	# The tool's NWN conversion maps NWN +Y to Godot -Z.
	var shaft := BoxMesh.new()
	shaft.size = Vector3(.025, .025, 1.9)
	_mesh(guides, shaft, Vector3(0, .015, -1), Color.GREEN)
	for sign_value in [-1, 1]:
		var head := BoxMesh.new()
		head.size = Vector3(.025, .025, .35)
		var item := _mesh(guides, head, Vector3(sign_value * .12, .015, -1.8), Color.GREEN)
		item.rotation.y = sign_value * PI / 4
	var body := CapsuleMesh.new()
	body.radius = .23
	body.height = 1.25
	_mesh(guides, body, Vector3(0, 1, -2.1), Color(.8,.35,.15))
	var head := SphereMesh.new()
	head.radius = .15
	head.height = .3
	_mesh(guides, head, Vector3(0, 1.8, -2.1), Color(.85,.6,.3))
	var text := Label3D.new()
	text.text = "FORWARD / TARGET"
	text.position = Vector3(0, 2.1, -2.1)
	text.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	guides.add_child(text)
	trail = MeshInstance3D.new()
	app.add_child(trail)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1,.4,.05)
	trail.material_override = mat

func clear_trail() -> void:
	trail_points.clear()
	last_time = -1
	if trail != null: trail.mesh = null

func _update_trail() -> void:
	if not trail_enabled: return
	var t: float = app.side_panel.timeline.current_time
	if t < last_time: clear_trail()
	last_time = t
	var weapon: Variant = app.side_panel._weapon_meshes.get("rhand")
	if not is_instance_valid(weapon) or not weapon.visible: return
	var tip: Vector3 = weapon.to_global(Vector3(0, weapon.mesh.height * .5, 0))
	if not trail_points.is_empty() and trail_points[-1].distance_to(tip) < .004: return
	trail_points.append(tip)
	if trail_points.size() > 800: trail_points.pop_front()
	if trail_points.size() < 2: return
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for v in trail_points: mesh.surface_add_vertex(v)
	mesh.surface_end()
	trail.mesh = mesh

func open_library(memory_slot: int = -1) -> void:
	library_memory_slot = memory_slot
	panel.hide()
	browser.title = "Pose library — slot %d: choose an animation" % (memory_slot + 1) if memory_slot >= 0 else "Pose library — F1 / F2 / F3 / NWN1 originals"
	browser.popup_centered(Vector2i(780, 580))
	_refresh_library()

func _build_library() -> void:
	browser = AcceptDialog.new()
	browser.visibility_changed.connect(func():
		if not browser.visible: library_memory_slot = -1)
	browser.title = "Pose library — F1 / F2 / F3 / NWN1 originals"
	app.add_child(browser)
	var box := VBoxContainer.new()
	browser.add_child(box)
	folder = OptionButton.new()
	for title in ["F1", "F2", "F3", "NWN1 originals", "My poses"]: folder.add_item(title)
	folder.item_selected.connect(func(_i): _refresh_library())
	box.add_child(folder)
	var config := ConfigFile.new()
	if config.load(library_config_path) == OK:
		for path in config.get_value("library","folders",[]):
			custom_pose_folders.append(str(path))
			folder.add_item(str(path))
	var folders_row := HBoxContainer.new()
	box.add_child(folders_row)
	_button(folders_row,"Add folder...",_choose_pose_folder)
	_button(folders_row,"Refresh",_refresh_library)
	library_status = Label.new()
	library_status.custom_minimum_size.x = 720
	library_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(library_status)
	pose_folder_dialog = FileDialog.new()
	pose_folder_dialog.access = FileDialog.ACCESS_FILESYSTEM
	pose_folder_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	pose_folder_dialog.title = "Choose a pose / animation folder"
	app.add_child(pose_folder_dialog)
	pose_folder_dialog.dir_selected.connect(_add_pose_folder)
	search = LineEdit.new()
	search.placeholder_text = "Filter by name..."
	search.text_changed.connect(func(_s): _refresh_library())
	box.add_child(search)
	entries = ItemList.new()
	entries.custom_minimum_size = Vector2(720, 360)
	entries.size_flags_vertical = Control.SIZE_EXPAND_FILL
	entries.max_columns = 5
	entries.fixed_column_width = 135
	entries.fixed_icon_size = Vector2i(100, 100)
	entries.icon_mode = ItemList.ICON_MODE_TOP
	entries.item_activated.connect(func(_i): _library_open())
	box.add_child(entries)
	var row := HBoxContainer.new()
	box.add_child(row)
	_button(row, "Open animation", _library_open)
	_button(row, "Preview animation", _library_preview)
	_button(row, "Use first pose", _library_pose)
	_button(row, "Compare", _compare_selected)
	_button(row, "Save current pose", _save_library_pose)
	_label(box, "Original references keep NWN axes and timing. Double-click opens an animation.")

func _library_path() -> String:
	if folder.selected >= 5: return custom_pose_folders[folder.selected - 5]
	if folder.selected == 3: return WorkshopSettings.path_value("references")
	if folder.selected == 4:
		DirAccess.make_dir_recursive_absolute("user://poses")
		return "user://poses"
	return WorkshopSettings.path_value("pose_root").path_join(folder.get_item_text(folder.selected))

func _refresh_library() -> void:
	thumb_generation += 1
	entries.clear()
	library.clear()
	var path := _library_path()
	var files := _pose_files(path, folder.selected >= 5)
	files.sort()
	for file in files:
		if file.get_extension().to_lower() not in ["txt", "mdl"]: continue
		if not search.text.is_empty() and not file.to_lower().contains(search.text.to_lower()): continue
		library.append(path.path_join(file))
		var display_name := file.get_basename()
		if display_name.contains("__"): display_name = display_name.split("__")[1]
		entries.add_item(display_name)
		entries.set_item_tooltip(entries.item_count - 1, path.path_join(file))
	library_status.text = "%d animations | %s" % [library.size(), path]
	if not DirAccess.dir_exists_absolute(path): library_status.text = "Folder not found: " + path
	if not thumb_busy: _generate_thumbnails()

func _find(root: Node, name_text: String) -> Node3D:
	if root.name == name_text: return root as Node3D
	return root.find_child(name_text, true, false) as Node3D

func _apply(rig: Node3D, pose: Dictionary) -> void:
	for key in pose:
		var node := _find(rig, key)
		if node != null: node.transform = pose[key]

func _make_view(parent: Node, size: Vector2i) -> Dictionary:
	var viewport := SubViewport.new()
	viewport.size = size
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	parent.add_child(viewport)
	var root := Node3D.new()
	viewport.add_child(root)
	var rig: Node3D = load(app._current_model_path).instantiate()
	root.add_child(rig)
	preload("res://scripts/game_staff_preview.gd").apply_hands(rig,app._current_model_path.ends_with("a_fa.glb"))
	app._apply_component_materials(rig)
	for node_name in ["cloak_g", "Cloak_g", "belt_g1"]:
		var node := _find(rig, node_name)
		if node != null: node.visible = false
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(.16,.18,.2)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color.WHITE
	env.environment.ambient_light_energy = .65
	root.add_child(env)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45,-35,0)
	root.add_child(light)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.position = Vector3(2.2,1.7,-3.5)
	camera.look_at(Vector3(0,1,0))
	if size.x <= 160:
		camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		camera.size = 2.25
	var hand := _find(rig,"rhand")
	if hand != null:
		var blade := CylinderMesh.new()
		blade.top_radius = .01
		blade.bottom_radius = .01
		blade.height = .6
		var w := _mesh(hand,blade,Vector3(0,-.06,-.3),Color.CYAN)
		w.rotation.x = -PI / 2
		if app.side_panel._show_hilt: app.side_panel._attach_hilt(w, false)
		app.side_panel.align_weapon_grip(w, hand, false)
	return {"viewport": viewport, "rig": rig, "camera": camera, "rest": MdlExporter.capture_pose(rig)}

func _generate_thumbnails() -> void:
	thumb_busy = true
	if thumb_world.is_empty(): thumb_world = _make_view(self, Vector2i(160,160))
	var generation := thumb_generation
	var paths := library.duplicate()
	for i in range(paths.size()):
		if generation != thumb_generation: break
		var cache_key: String = paths[i] + str(FileAccess.get_modified_time(paths[i])) + app._current_model_path
		if thumbnail_cache.has(cache_key):
			entries.set_item_icon(i, thumbnail_cache[cache_key])
			continue
		_apply(thumb_world.rig, thumb_world.rest)
		var result: Variant = MdlImporter.parse(FileAccess.get_file_as_string(paths[i]), thumb_world.rig)
		if result == null: continue
		_apply(thumb_world.rig, result.keyframes[0].transforms)
		thumb_world.viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		await RenderingServer.frame_post_draw
		if generation != thumb_generation: break
		var img: Image = thumb_world.viewport.get_texture().get_image()
		if img != null:
			var texture := ImageTexture.create_from_image(img)
			thumbnail_cache[cache_key] = texture
			entries.set_item_icon(i, texture)
	thumb_busy = false
	thumb_world.viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if generation != thumb_generation: _generate_thumbnails()

func _selected_path() -> String:
	var selected := entries.get_selected_items()
	return library[selected[0]] if not selected.is_empty() else ""

func _library_open() -> void:
	var path := _selected_path()
	if path.is_empty(): return
	app._on_open_file_requested(path, library_memory_slot)
	browser.hide()

func _library_pose() -> void:
	if library_memory_slot >= 0:
		_library_open()
		return
	var path := _selected_path()
	if path.is_empty(): return
	if thumb_world.is_empty(): thumb_world = _make_view(self, Vector2i(160,160))
	_apply(thumb_world.rig, thumb_world.rest)
	var result: Variant = MdlImporter.parse(FileAccess.get_file_as_string(path), thumb_world.rig)
	if result == null: return
	app._push_undo_snapshot()
	release_constraints()
	app._apply_transforms(result.keyframes[0].transforms)
	browser.hide()

func _save_library_pose() -> void:
	DirAccess.make_dir_recursive_absolute("user://poses")
	var title: String = app.side_panel.get_anim_name().validate_filename()
	if title.is_empty(): title = "pose"
	var path := "user://poses/%s_%d.txt" % [title, Time.get_unix_time_from_system()]
	app._on_save_file_requested(path, title, true)
	folder.select(4)
	_refresh_library()

func _compare_selected() -> void:
	var path := _selected_path()
	if path.is_empty(): return
	if comparison != null: comparison.queue_free()
	comparison = Window.new()
	comparison.title = "Current animation | " + path.get_file()
	comparison.size = Vector2i(1000,620)
	app.add_child(comparison)
	comparison.close_requested.connect(comparison.hide)
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	comparison.add_child(box)
	var row := HBoxContainer.new()
	box.add_child(row)
	_button(row,"Play / Pause",func(): app._on_play_toggled(not app._playing))
	_button(row,"Restart",func(): app._play_time = 0; app._on_timeline_scrubbed(0); app.side_panel.timeline.set_current_time(0))
	var normalized := _check(row,"Match animation phase",func(v): normalize_time = v)
	normalized.button_pressed = normalize_time
	_label(box,"Left: current animation     Right: reference     Camera follows the main viewport")
	row = HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(row)
	views.clear()
	for i in range(2):
		var container := SubViewportContainer.new()
		container.stretch = true
		container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(container)
		views.append(_make_view(container,Vector2i(480,500)))
	var parsed: Variant = MdlImporter.parse(FileAccess.get_file_as_string(path), views[1].rig)
	if parsed == null: comparison.hide(); return
	reference = parsed
	browser.hide()
	comparison.popup_centered()
	_update_comparison()

func _sample(keys: Array, t: float) -> Dictionary:
	if keys.is_empty(): return {}
	var a: Dictionary = keys[0]
	var b: Dictionary = keys[-1]
	if t <= a.time: return a.transforms
	if t >= b.time: return b.transforms
	for i in range(keys.size()-1):
		if keys[i].time <= t and t <= keys[i+1].time:
			a = keys[i]
			b = keys[i+1]
			break
	var weight: float = (t-a.time)/max(b.time-a.time,.00001)
	var pose := {}
	for node in a.transforms:
		var ta: Transform3D = a.transforms[node]
		var tb: Transform3D = b.transforms.get(node,ta)
		pose[node] = ta.interpolate_with(tb,weight)
	return pose

func _update_comparison() -> void:
	if reference.is_empty(): return
	_apply(views[0].rig, MdlExporter.capture_pose(app.get_node("Rig")))
	var t: float = app.side_panel.timeline.current_time
	if normalize_time: t = t / max(app._anim_length,.001) * reference.length
	_apply(views[1].rig, _sample(reference.keyframes,t))
	var cam: Camera3D = app.get_node("Camera3D")
	for view in views:
		view.camera.transform = cam.transform
		view.camera.projection = cam.projection
		view.camera.size = cam.size

func _choose_pose_folder() -> void:
	pose_folder_dialog.popup_centered_ratio(.75)

func _add_pose_folder(path: String) -> void:
	path = path.simplify_path()
	if not DirAccess.dir_exists_absolute(path):
		app.side_panel.set_status("Folder not found: " + path)
		return
	var index := custom_pose_folders.find(path)
	if index < 0:
		custom_pose_folders.append(path)
		folder.add_item(path)
		index = custom_pose_folders.size() - 1
	var config := ConfigFile.new()
	config.set_value("library","folders",custom_pose_folders)
	var error := config.save(library_config_path)
	if error != OK: app.side_panel.set_status("Folder added for this session; could not save folder list.")
	folder.select(5 + index)
	search.text = ""
	browser.popup_centered(Vector2i(820,600))
	_refresh_library()

func _pose_files(path: String, recursive: bool, depth: int = 0) -> PackedStringArray:
	var files := PackedStringArray()
	if not DirAccess.dir_exists_absolute(path): return files
	for name in DirAccess.get_files_at(path):
		if name.get_extension().to_lower() in ["txt","mdl"]: files.append(name)
	if recursive and depth < 8:
		for name in DirAccess.get_directories_at(path):
			if name.begins_with("."): continue
			for child in _pose_files(path.path_join(name),true,depth+1): files.append(name.path_join(child))
	return files

func _library_preview() -> void:
	if library_memory_slot >= 0:
		_library_open()
		return
	var path := _selected_path()
	if path.is_empty(): return
	if not app.mdl_bank.recognizes(path) and MdlImporter.parse(FileAccess.get_file_as_string(path),app.get_node("Rig")) == null:
		app.side_panel.set_status("Cannot preview: this file contains no supported animation.")
		return
	app._on_play_toggled(false)
	_library_open()
	# A full bank first asks the user to choose a clip in its own dialog.
	if not app.mdl_bank.recognizes(path) and not app._keyframes.is_empty():
		app.side_panel.set_playing(true)
		app._on_play_toggled(true)
