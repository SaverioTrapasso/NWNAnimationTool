## Runs detect_pose.py as a subprocess (via OS.execute on a background
## Thread) and emits pose_received / pose_failed when done.
## No HTTP server needed — just Python installed somewhere on the machine.
extends Node

signal pose_received(world_landmarks: Array)
signal pose_failed(error: String)

const SCRIPT_PATH := "res://ai_pose/detect_pose.py"

var _thread: Thread = null
var _result: Dictionary = {}

func _exit_tree() -> void:
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()

## Resolves a res:// script to a real on-disk path that OS.execute can run.
## In the editor res:// is a real folder, so the path maps directly; in an
## exported build the file lives INSIDE the .pck where no external process
## can reach it, so it gets copied to user:// (writable, real path) first.
static func extract_to_disk(res_path: String) -> String:
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path(res_path)
	var bytes := FileAccess.get_file_as_bytes(res_path)
	if bytes.is_empty():
		return ""
	var dest := "user://" + res_path.get_file()
	var f := FileAccess.open(dest, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_buffer(bytes)
	f.close()
	return ProjectSettings.globalize_path(dest)

## Find a working Python executable on this machine.
## Tries common names in PATH, then the Windows launcher.
static func _find_python() -> String:
	var candidates := [
		"python",
		"python3",
		"py",
	]
	for candidate in candidates:
		var output: Array = []
		var code := OS.execute(candidate, ["--version"], output, true, true)
		if code == 0:
			return candidate
	return ""

## Send an image file to MediaPipe for pose detection.
## image_path must be an absolute filesystem path.
func detect(image_path: String) -> void:
	if _thread != null and _thread.is_started():
		pose_failed.emit("Already processing an image — please wait.")
		return

	var script_abs: String = extract_to_disk(SCRIPT_PATH)
	if script_abs == "" or not FileAccess.file_exists(script_abs):
		pose_failed.emit("detect_pose.py could not be prepared (%s)" % SCRIPT_PATH)
		return

	_thread = Thread.new()
	_thread.start(_run_in_thread.bind(image_path, script_abs))

func _run_in_thread(image_path: String, script_abs: String) -> void:
	var python := _find_python()
	if python == "":
		_result = {"error": "Python not found. Install Python 3.10+ from python.org"}
		call_deferred("_on_thread_done")
		return

	var output: Array = []
	var code := OS.execute(python, [script_abs, image_path], output, true, true)

	var stdout: String = ""
	for line in output:
		stdout += line

	if stdout.strip_edges() == "":
		_result = {"error": "No output from detect_pose.py (exit code %d)" % code}
		call_deferred("_on_thread_done")
		return

	# Find the last line that looks like JSON (MediaPipe prints warnings to stderr
	# but OS.execute may interleave them into output on some platforms)
	var json_line := ""
	for line in stdout.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.begins_with("{"):
			json_line = trimmed

	var json := JSON.new()
	if json_line == "" or json.parse(json_line) != OK:
		_result = {"error": "Could not parse JSON output: %s" % stdout.left(200)}
		call_deferred("_on_thread_done")
		return

	_result = json.get_data()
	call_deferred("_on_thread_done")

func _on_thread_done() -> void:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null

	if _result.has("error"):
		pose_failed.emit(_result["error"])
	else:
		var wl: Array = _result.get("world_landmarks", [])
		if wl.is_empty():
			pose_failed.emit("No pose detected in image")
		else:
			pose_received.emit(wl)
	_result = {}
