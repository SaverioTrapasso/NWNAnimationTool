extends SceneTree

var failures: Array[String] = []
func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); push_error(message)

func run() -> void:
	var app = load("res://scenes/Main.tscn").instantiate()
	root.add_child(app)
	await process_frame
	var rig = app.get_node("Rig")
	var text := "newanim test model\nlength 1\nnode dummy rootdummy\nparent model\npositionkey 3\n0 0 0 1\n0.5 1 0 1\n1 2 0 1\norientationkey 2\n0 0 0 1 -0.4\n1 0 0 1 -0.8\nendnode\nnode dummy Lbicep_g\nparent torso_g\norientation 0 1 0 0.3\nendnode\ndoneanim test model"
	var parsed = MdlImporter.parse(text,rig)
	check(parsed != null,"Counted MDL keys")
	check(parsed.keyframes.size() == 3,"Position-only timestamps")
	check(parsed.keyframes[1].transforms.rootdummy.origin.distance_to(Vector3(1,1,0)) < .0001,"Position interpolation")
	check(parsed.keyframes[1].transforms.rootdummy.basis.get_rotation_quaternion().angle_to(Quaternion(Vector3.UP,-.6))<.002,"Signed rotation interpolation")
	var lower = MdlImporter.parse(text.to_lower(),rig)
	check(parsed.keyframes == lower.keyframes,"Case-insensitive bone names")
	check(MdlImporter.parse(text+"\n"+text,rig) == null,"Do not merge full model clips silently")
	app._keyframes = parsed.keyframes
	app._anim_length = 1
	app._on_duration_changed(2)
	check(app._keyframes[-1].time == 2,"Scale timeline")
	app._undo()
	check(app._keyframes[-1].time == 1,"Undo timeline")
	app._redo()
	check(app._keyframes[-1].time == 2,"Redo timeline")
	app.side_panel.set_anim_name("test")
	app._on_pose_memory_save(0)
	check(app._pose_memory_names[0] == "test","Named pose memory")
	check(app.side_panel._pose_memory_load_buttons.size() == 5, "Five pose memory slots")
	for slot in 5:
		check(app.side_panel._sidebar.has_node("PoseMemory/Slot%d/OpenButton" % (slot + 1)), "Open button on every slot")
	var memory_path := "user://memory-smoke.txt"
	var memory_file := FileAccess.open(memory_path, FileAccess.WRITE)
	memory_file.store_string(text)
	memory_file.close()
	app._on_pose_memory_open(4)
	check(app.qol.browser.visible and app.qol.library_memory_slot == 4, "Slot Open uses Pose Library")
	app.qol.library = [memory_path]
	app.qol.entries.clear()
	app.qol.entries.add_item("test")
	app.qol.entries.select(0)
	app.qol._library_open()
	check(app.qol.library_memory_slot == -1, "Library closes without retaining slot target")
	check(app._pose_memory_names[4] == "test", "Open remembers animation name")
	check(app._pose_memory_clips[4].keyframes.size() == 3, "Open stores complete animation")
	app._keyframes.clear()
	app._on_pose_memory_load(4)
	check(app._keyframes.is_empty(), "Load pose does not replace timeline")
	app._pose_memory[4]["rootdummy"].origin.x += .1
	check(app._pose_memory_clips[4].keyframes[0].time == 0, "Saved animation is independent of editing")
	app._on_open_file_requested("user://missing-memory-clip.txt", 4)
	check(app._pose_memory_clips[4].keyframes.size() == 3, "Failed open preserves slot")
	app._on_pose_memory_save(4)
	check(app._pose_memory_clips[4] == null, "Save keeps original single-pose behavior")
	app._on_pose_memory_open(2)
	app.qol.browser.hide()
	check(app.qol.library_memory_slot == -1, "Cancel clears slot target")
	DirAccess.remove_absolute(memory_path)
	for staff in [false,true]:
		app.side_panel._on_double_staff_toggled(staff)
		var blade = app.side_panel._weapon_meshes.rhand
		var hand = app.rig_controller.find_node("rhand_g")
		if blade.has_meta("game_resource"):
			check(blade.transform.is_equal_approx(Transform3D.IDENTITY),"Real game hilt preserves attachment")
		else:
			check(blade.to_global(Vector3(0,-.18,0) if staff else blade.get_node("LightsaberHilt").position).distance_to(hand.to_global(hand.mesh.get_aabb().get_center()))<.0001,"Centered hilt")
	app.qol._pin("right_leg",true)
	var foot = app.rig_controller.find_node("rfoot_g")
	var pinned: Vector3 = foot.global_position
	app.rig_controller.find_node("rootdummy").position.y -= .02
	app.qol.apply_constraints()
	check(foot.global_position.distance_to(pinned)<.002,"Foot pin")
	app.mdl_bank._apply_preview_rig("female")
	check(app._current_model_path.ends_with("a_fa.glb"),"Female MDL uses female preview")
	var neck = app.rig_controller.find_node("neck_g")
	check(abs(app._rest_transforms[neck].origin.y - .34636)<.001,"Female neck height matches MDL")
	app.mdl_bank._apply_preview_rig("male")
	check(app._current_model_path.ends_with("a_ba.glb"),"Male MDL uses male preview")
	app.rig_controller.select_component("right_upper_arm")
	check(app.rig_controller._node_to_component.rforearm_g == "right_forearm", "Separate forearm picking")
	app.rig_controller.select_component("left_calf", true)
	check(app.rig_controller.selected_components.size() == 2, "Shift adds selection")
	var arm = app.rig_controller.find_node("rbicep_g")
	var calf = app.rig_controller.find_node("lshin_g")
	check(app._attachment_translate_handle != null, "Multi-selection has translation arrows")
	var offsets = MdlExporter.capture_pose(app.get_node("Rig"))
	var arm_before_move = arm.basis
	app._on_panel_position_changed(app._translation_anchor() + Vector3(.08,0,.06))
	check(not arm.basis.is_equal_approx(arm_before_move), "Arrows rotate connected joint")
	for name in offsets:
		check(app.rig_controller.find_node(name).position.is_equal_approx(offsets[name].origin), "Bone connection preserved: " + name)
	var arm_before = arm.basis
	var calf_before = calf.basis
	var turn = Basis(Vector3.UP, .15)
	app._rotate_selection(arm_before * turn)
	check(arm.basis.is_equal_approx(arm_before * turn), "Group rotates arm")
	check(calf.basis.is_equal_approx(calf_before * turn), "Group rotates calf")
	await process_frame
	check(arm.basis.is_equal_approx(arm_before * turn), "IK does not overwrite FK arm")
	app.rig_controller.select_component("left_calf", true)
	check(app.rig_controller.selected_components.size() == 1, "Shift removes selection")
	app.rig_controller.select_component("right_forearm", true)
	check(app.rig_controller.selection_roots().size() == 1, "Parent-child selection avoids double rotation")
	for part in ["right_upper_arm", "right_forearm", "right_hand", "left_thigh", "left_calf", "left_foot"]:
		app.rig_controller.select_component(part)
		check(app._attachment_translate_handle.global_position.is_equal_approx(app.gizmo.target.global_position), "Arrows share rotation pivot: " + part)
		var start_basis = app.gizmo.target.basis
		app._rotate_selection(start_basis * Basis(Vector3.UP,.1))
		await process_frame
		check(app.gizmo.target.basis.is_equal_approx(start_basis * Basis(Vector3.UP,.1)), "Selected part rotation survives IK: " + part)
		app._begin_selection_translation()
		var destination = app._translation_anchor() + Vector3(.02,.01,.01)
		app._translate_selection(destination)
		var first = MdlExporter.capture_pose(app.get_node("Rig"))
		app._translate_selection(destination)
		var second = MdlExporter.capture_pose(app.get_node("Rig"))
		for name in first: check(first[name].is_equal_approx(second[name]), "Drag does not accumulate: " + name)
	app.rig_controller.deselect()
	check(app.rig_controller.selected_components.is_empty(), "Clear multi-selection")
	app.rig_controller.select_component("right_thigh")
	app.get_viewport().gui_release_focus()
	var before_key = MdlExporter.capture_pose(app.get_node("Rig"))
	var key = InputEventKey.new()
	key.keycode = KEY_LEFT
	key.pressed = true
	check(app._nudge_selection(key), "Keyboard arrow handled")
	for name in before_key: check(app.rig_controller.find_node(name).position.is_equal_approx(before_key[name].origin), "Keyboard preserves bone offsets")
	app._undo()
	var after_undo = MdlExporter.capture_pose(app.get_node("Rig"))
	for name in before_key: check(after_undo[name].is_equal_approx(before_key[name]), "Keyboard undo restores pose")
	app._on_overlay_toggled(true)
	check(app._nwn_skeleton.visible and app._nwn_skeleton_mesh.get_surface_count() == 1, "Skel displays native hierarchy without source")
	app._on_overlay_toggled(false)
	check(not app._nwn_skeleton.visible, "Skel hides native hierarchy")
	app.rig_controller.select_all_body()
	check(app.rig_controller.all_body_selected(), "All body parts selected")
	check(app.rig_controller.selection_roots().size()==1, "Select all transforms root once")
	var root_node=app.rig_controller.find_node("rootdummy")
	var origin=root_node.global_position
	app._on_panel_position_changed(origin+Vector3(.05,0,0))
	check(root_node.global_position.is_equal_approx(origin+Vector3(.05,0,0)), "Select all moves complete rig")
	print("WORKSHOP_SMOKE failures=",failures.size())
	quit(0 if failures.is_empty() else 1)
