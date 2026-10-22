extends SceneTree
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var app = load("res://scenes/Main.tscn").instantiate()
	root.add_child(app)
	await process_frame
	var timeline = app.side_panel.timeline
	var pose = MdlExporter.capture_pose(app.get_node("Rig"))
	app._keyframes = []
	for i in 6: app._keyframes.append({"time":float(i),"transforms":pose.duplicate(true)})
	app._refresh_timeline_markers()
	timeline.select_key(1.0)
	timeline.select_key(4.0,true)
	assert(timeline.selected_times == [1.0,2.0,3.0,4.0])
	app._on_remove_key_requested()
	assert(app._keyframes.size()==2 and app._keyframes[1].time==5.0)
	app._undo()
	assert(app._keyframes.size()==6)
	timeline.select_key(4.0)
	timeline.select_key(1.0,true)
	assert(timeline.selected_times == [1.0,2.0,3.0,4.0])
	var event := InputEventKey.new()
	event.keycode=KEY_DELETE
	event.pressed=true
	timeline._gui_input(event)
	assert(app._keyframes.size()==2)
	app._undo()
	timeline.select_key(0.0)
	timeline.select_key(5.0,true)
	app._on_remove_key_requested()
	assert(app._keyframes.is_empty())
	app._undo()
	assert(app._keyframes.size()==6)
	print("TIMELINE_RANGE_OK forward, reverse, Remove, Delete, Undo, delete all")
	quit()
