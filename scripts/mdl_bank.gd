extends Node

var python := ""
var backend_path := ""
var app: Node3D
var dialog: AcceptDialog
var file_dialog: FileDialog
var dependency_dialog: FileDialog
var list: ItemList
var search: LineEdit
var info: Label
var status: Label
var session := ""
var model := ""
var active_clip := ""
var loading_clip := false
var busy := false
var baseline := ""
var dependency_folder := ""
var game_data := ""
var thread: Thread
var callback: Callable
var response_path := ""
var buttons: Array[Button] = []
var clips: Array = []
var export_mode := false

func _ready() -> void:
	app = get_parent()
	backend_path = WorkshopSettings.extract_backend()
	dependency_folder = WorkshopSettings.path_value("dependencies")
	game_data = WorkshopSettings.path_value("game_data")
	dialog = AcceptDialog.new()
	dialog.title = "NWN1 MDL animation bank"
	app.add_child(dialog)
	var box := VBoxContainer.new()
	dialog.add_child(box)
	info = Label.new()
	info.text = "Open a full ASCII or binary NWN1 model."
	box.add_child(info)
	search = LineEdit.new()
	search.placeholder_text = "Find animation..."
	search.text_changed.connect(func(_value): _refresh_list())
	box.add_child(search)
	list = ItemList.new()
	list.custom_minimum_size = Vector2(600,320)
	box.add_child(list)
	list.item_activated.connect(func(_i): load_selected())
	var row := HBoxContainer.new()
	box.add_child(row)
	_add_button(row,"Open MDL...",choose_open)
	_add_button(row,"Load selected",load_selected)
	_add_button(row,"Save edits to bank",func(): save_current(func(_r): _status("Animation saved in working bank.")))
	row = HBoxContainer.new()
	box.add_child(row)
	_add_button(row,"Export compiled MDL...",choose_export)
	_add_button(row,"Dependencies folder...",func(): dependency_dialog.popup_centered_ratio(.7))
	_add_button(row,"Game data folder...",choose_game_data)
	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.custom_minimum_size = Vector2(600,65)
	box.add_child(status)
	_status("Edits use timeline keys. Press Set after changing a pose. Export keeps the original model name.")
	file_dialog = FileDialog.new()
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.filters = PackedStringArray(["*.mdl ; NWN1 model"])
	app.add_child(file_dialog)
	file_dialog.file_selected.connect(func(path):
		if export_mode: export_to(path)
		else: open_bank(path))
	dependency_dialog = FileDialog.new()
	dependency_dialog.access = FileDialog.ACCESS_FILESYSTEM
	dependency_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	app.add_child(dependency_dialog)
	dependency_dialog.dir_selected.connect(func(path): dependency_folder = path; WorkshopSettings.save_path("dependencies",path); _status("Dependencies: " + path))
	var menu: PopupMenu = app.side_panel.file_menu.get_popup()
	menu.add_separator()
	menu.add_item("Open MDL bank...",20)
	menu.add_item("MDL bank / Export compiled model...",21)
	menu.id_pressed.connect(func(id):
		if id == 20: choose_open()
		elif id == 21: show_bank())

func _add_button(parent: Node, title: String, action: Callable) -> void:
	var b := Button.new()
	b.text = title
	b.pressed.connect(action)
	parent.add_child(b)
	buttons.append(b)

func show_bank() -> void: dialog.popup_centered(Vector2i(720,520))

func choose_game_data() -> void:
	var picker := FileDialog.new()
	picker.access = FileDialog.ACCESS_FILESYSTEM
	picker.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	app.add_child(picker)
	picker.dir_selected.connect(func(path): game_data = path; WorkshopSettings.save_path("game_data",path); _status("NWN data: " + path); picker.queue_free())
	picker.canceled.connect(picker.queue_free)
	picker.popup_centered_ratio(.7)

func choose_open() -> void:
	if busy: return
	export_mode = false
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.current_file = ""
	file_dialog.popup_centered_ratio(.75)

func choose_export() -> void:
	if session.is_empty(): _status("Open an MDL bank first."); return
	export_mode = true
	file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	file_dialog.current_file = model + ".mdl"
	file_dialog.popup_centered_ratio(.75)

func recognizes(path: String) -> bool:
	var f := FileAccess.open(path,FileAccess.READ)
	if f == null: return false
	var data := f.get_buffer(8192)
	if data.size() >= 4 and data.slice(0,4) == PackedByteArray([0,0,0,0]): return true
	return data.get_string_from_utf8().to_lower().contains("newmodel ")

func open_bank(path: String) -> void:
	if busy: return
	if not active_clip.is_empty(): save_current(func(_r): _open_new_bank(path))
	else: _open_new_bank(path)

func _open_new_bank(path: String) -> void:
	var root_path := OS.get_user_data_dir().path_join("mdl-sessions")
	DirAccess.make_dir_recursive_absolute(root_path)
	var next_session := root_path.path_join(str(Time.get_unix_time_from_system()).replace(".","_")+"_"+str(Time.get_ticks_usec()))
	show_bank()
	_request({"action":"open","source":path,"session":next_session},func(result):
		session = result.session
		model = result.model
		active_clip = ""
		baseline = ""
		clips = result.clips
		_refresh_list()
		info.text = "%s | %d animations | supermodel: %s" % [model,clips.size(),result.supermodel]
		_status("Select an animation and click Load selected. Original file is unchanged."))

func _refresh_list() -> void:
	list.clear()
	for i in range(clips.size()):
		var clip: Dictionary = clips[i]
		if not search.text.is_empty() and not clip.name.to_lower().contains(search.text.to_lower()): continue
		list.add_item("%s    %.3f s    %d events" % [clip.name,clip.length,clip.events])
		list.set_item_metadata(list.item_count-1,i)
		if clip.name == active_clip: list.select(list.item_count-1)

func load_selected() -> void:
	if busy or list.get_selected_items().is_empty(): return
	var name_text: String = clips[list.get_item_metadata(list.get_selected_items()[0])].name
	var next := func(_result): _request({"action":"preview","session":session,"animation":name_text},func(result):
		loading_clip = true
		app._on_play_toggled(false)
		_apply_preview_rig(result.get("rig", ""))
		app._on_open_file_requested(result.preview)
		loading_clip = false
		active_clip = name_text
		baseline = MdlExporter.export_animation(app.get_node("Rig"),active_clip,app._anim_length,app._keyframes)
		_status("Editing " + active_clip + ". Other animation edits remain in the working bank.")
		dialog.hide())
	if not active_clip.is_empty(): save_current(next)
	else: next.call({})

func save_current(done: Callable) -> void:
	if busy: return
	if active_clip.is_empty(): done.call({}); return
	var edited := session.path_join("edited.txt")
	var before := session.path_join("baseline.txt")
	var current := MdlExporter.export_animation(app.get_node("Rig"),active_clip,app._anim_length,app._keyframes)
	var f := FileAccess.open(edited,FileAccess.WRITE)
	if f == null: _status("Cannot save temporary edited clip."); return
	f.store_string(current);f.close()
	f = FileAccess.open(before,FileAccess.WRITE)
	if f == null: _status("Cannot save temporary baseline."); return
	f.store_string(baseline);f.close()
	_request({"action":"stage","session":session,"animation":active_clip,"edited":edited,"baseline":before},func(result):
		baseline = current
		clips = result.clips
		_refresh_list()
		done.call(result))

func export_to(path: String) -> void:
	if busy or session.is_empty(): return
	if path.get_extension().is_empty(): path += ".mdl"
	save_current(func(_r): _request({"action":"export","session":session,"output":path,"dependencies":dependency_folder,"game_data":game_data},func(result):
		_status("Validated NWN1 MDL saved: " + result.output + "\nAnimations: " + str(result.animations))))

func _status(text: String) -> void:
	status.text = text
	app.side_panel.set_status(text)

func _request(request: Dictionary, done: Callable) -> void:
	if busy: return
	python = WorkshopSettings.path_value("python")
	request["compiler"] = WorkshopSettings.path_value("compiler")
	request["dependencies"] = WorkshopSettings.path_value("dependencies")
	request["game_data"] = WorkshopSettings.path_value("game_data")
	if not FileAccess.file_exists(backend_path):
		_status("MDL compiler helper or Python runtime is missing."); return
	var temp := OS.get_user_data_dir().path_join("mdl-jobs")
	DirAccess.make_dir_recursive_absolute(temp)
	var id := str(Time.get_ticks_usec())
	var input := temp.path_join(id+".request.json")
	response_path = temp.path_join(id+".response.json")
	var file := FileAccess.open(input,FileAccess.WRITE)
	if file == null: _status("Cannot write MDL job."); return
	file.store_string(JSON.stringify(request));file.close()
	busy = true
	callback = done
	for b in buttons: b.disabled = true
	_status("Working: " + request.action + "...")
	thread = Thread.new()
	thread.start(_run.bind(input,response_path))

func _run(input: String, output_file: String) -> int:
	var output: Array = []
	return OS.execute(_python_executable(),[backend_path,input,output_file],output,true,false)

func _process(_delta: float) -> void:
	if not busy or thread.is_alive(): return
	var code: int = thread.wait_to_finish()
	busy = false
	for b in buttons: b.disabled = false
	var result: Variant = JSON.parse_string(FileAccess.get_file_as_string(response_path))
	if not result is Dictionary or not result.get("ok",false):
		_status(result.get("error","Compiler helper failed: " + str(code)) if result is Dictionary else "Compiler helper failed: " + str(code))
		show_bank()
		return
	callback.call(result)

func _exit_tree() -> void:
	if thread != null and thread.is_started(): thread.wait_to_finish()

func _python_executable() -> String:
	if not python.is_empty(): return python
	for candidate in ["python3", "python", "py"]:
		var output: Array = []
		if OS.execute(candidate,["--version"],output,true,false) == 0: return candidate
	return "python3"

func import_references() -> void:
	show_bank()
	_request({"action":"references","output":ProjectSettings.globalize_path(WorkshopSettings.path_value("references"))},func(result):
		WorkshopSettings.save_path("idle",result.idle)
		if app._keyframes.is_empty(): app._apply_nwn_idle()
		_status("Imported %d reference clips from your local NWN installation." % result.files.size()))

func _apply_preview_rig(rig: String) -> void:
	if rig == "female": app._on_gender_selected("res://assets/nwn/a_fa.glb")
	elif rig == "male": app._on_gender_selected("res://assets/nwn/a_ba.glb")

# Memory imports use their own backend session and do not touch the editing bank.
func open_memory_bank(path: String, slot: int) -> void:
	if busy:
		app.side_panel.set_status("MDL bank is busy. Try again when it finishes.")
		return
	var memory_session := OS.get_user_data_dir().path_join("mdl-sessions/memory_" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(memory_session.get_base_dir())
	_request({"action":"open", "source":path, "session":memory_session}, func(result):
		var picker := ConfirmationDialog.new()
		picker.title = "Pose Memory %d — choose animation" % (slot+1)
		var choices := ItemList.new()
		choices.custom_minimum_size = Vector2(500,320)
		picker.add_child(choices)
		app.add_child(picker)
		for clip in result.clips: choices.add_item(clip.name)
		if choices.item_count > 0: choices.select(0)
		var accept := func():
			if choices.get_selected_items().is_empty() or busy: return
			var clip_name := choices.get_item_text(choices.get_selected_items()[0])
			_request({"action":"preview","session":memory_session,"animation":clip_name},func(preview):
				app._import_pose_memory(preview.preview,slot))
			picker.queue_free()
		picker.confirmed.connect(accept)
		choices.item_activated.connect(func(_index): accept.call())
		picker.canceled.connect(picker.queue_free)
		picker.popup_centered())
