class_name WorkshopSettings
extends RefCounted

const FILE := "user://workshop-settings.cfg"
const DEFAULTS := {"python":"", "pose_python":"", "compiler":"", "game_data":"", "dependencies":"", "pose_root":"", "references":"user://references", "idle":""}
const BACKEND_FILES := ["bridge.py", "vendor/CompileModels.py", "vendor/RobePoseAudit.py", "vendor/stock_resources.py", "vendor/LICENSE-SWLOR.txt"]

static func path_value(key: String) -> String:
	var config := ConfigFile.new()
	config.load(FILE)
	return str(config.get_value("paths", key, DEFAULTS.get(key, "")))

static func save_path(key: String, value: String) -> void:
	var config := ConfigFile.new()
	config.load(FILE)
	config.set_value("paths", key, value)
	var err := config.save(FILE)
	if err != OK: push_error("Cannot save Workshop settings: " + error_string(err))

static func extract_backend() -> String:
	var directory := OS.get_user_data_dir().path_join("mdl-backend")
	for relative in BACKEND_FILES:
		var source: String = "res://mdl_bank/" + relative
		var destination := directory.path_join(relative)
		DirAccess.make_dir_recursive_absolute(destination.get_base_dir())
		var output := FileAccess.open(destination, FileAccess.WRITE)
		if output == null: return ""
		output.store_buffer(FileAccess.get_file_as_bytes(source))
		output.close()
	return directory.path_join("bridge.py")

static func show_dialog(parent: Node) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Workshop settings — local files only"
	parent.add_child(dialog)
	var box := VBoxContainer.new()
	dialog.add_child(box)
	var labels := {"pose_python":"Pose Python executable (MediaPipe + OpenCV)", "python":"Python executable (empty: search PATH)", "compiler":"Supported nwnmdlcomp executable", "game_data":"NWN installation data folder", "dependencies":"Custom supermodel folder", "pose_root":"Pose library folder containing F1 / F2 / F3", "references":"Local NWN reference library folder", "idle":"Default idle animation block (optional)"}
	for key in labels:
		var label := Label.new()
		label.text = labels[key]
		box.add_child(label)
		var row := HBoxContainer.new()
		box.add_child(row)
		var edit := LineEdit.new()
		edit.custom_minimum_size.x = 460
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		edit.text = path_value(key)
		edit.text_changed.connect(func(value): save_path(key,value))
		row.add_child(edit)
		var browse := Button.new()
		browse.text = "Browse..."
		row.add_child(browse)
		browse.pressed.connect(func():
			var picker := FileDialog.new()
			picker.access = FileDialog.ACCESS_FILESYSTEM
			picker.file_mode = FileDialog.FILE_MODE_OPEN_FILE if key in ["python","pose_python","compiler","idle"] else FileDialog.FILE_MODE_OPEN_DIR
			parent.add_child(picker)
			var accept := func(path): edit.text = path; save_path(key,path); picker.queue_free()
			picker.file_selected.connect(accept)
			picker.dir_selected.connect(accept)
			picker.canceled.connect(picker.queue_free)
			picker.popup_centered_ratio(.75))
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered(Vector2i(640,610))
