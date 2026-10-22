extends SceneTree
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var app = load("res://scenes/Main.tscn").instantiate()
	root.add_child(app)
	await process_frame
	var pose = MdlExporter.capture_pose(app.get_node("Rig"))
	app._keyframes = [{"time":0.0,"transforms":pose.duplicate(true)},{"time":3.0,"transforms":pose.duplicate(true)}]
	app._anim_length=3.0
	app.side_panel.set_anim_name("working_scene")
	app.side_panel.set_duration(3.0)
	app.side_panel.timeline.set_current_time(1.7)
	app._refresh_timeline_markers()
	app.side_panel.timeline.select_key(3.0)
	var before = app._document_state()
	var camera: Transform3D = app.get_node("Camera3D").transform
	var content = "newanim slot_%d model\nlength 1\nnode dummy rootdummy\nparent model\npositionkey 1\n0 %d 0 1\nendnode\ndoneanim slot_%d model"
	for slot in [0,1,4]:
		var file := FileAccess.open("user://memory-scene-test.txt", FileAccess.WRITE)
		file.store_string(content % [slot,slot,slot]);file.close()
		app._on_open_file_requested("user://memory-scene-test.txt",slot)
		assert(app._document_state()==before)
		assert(app.get_node("Camera3D").transform==camera)
		assert(app.side_panel.timeline.selected_times==[3.0])
	for slot in [4,0,1]:
		app._on_pose_memory_load(slot)
		assert(app._keyframes==before.keys)
		assert(app._anim_length==3.0 and app.side_panel.timeline.current_time==1.7)
		assert(app.side_panel.get_anim_name()=="working_scene")
		assert(app.get_node("Camera3D").transform==camera)
		assert(app._pose_memory_names[slot]=="slot_%d" % slot)
	app._undo()
	assert(app._keyframes==before.keys)
	DirAccess.remove_absolute("user://memory-scene-test.txt")
	print("POSE_MEMORY_SCENE_OK: multiple slots preserve timeline, time, name, camera; Undo works")
	quit()
