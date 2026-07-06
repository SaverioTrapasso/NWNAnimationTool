## Runs extract_video_poses.py as a subprocess on a background Thread.
## Emits extraction_done(frames_array, duration) or extraction_failed(error).
extends Node

signal extraction_done(frames: Array, duration: float)
signal extraction_failed(error: String)
signal extraction_progress(message: String)

const SCRIPT_PATH := "res://ai_pose/extract_video_poses.py"
const AIPoseClient = preload("res://scripts/ai_pose_client.gd")

var _thread: Thread = null
var _result: Dictionary = {}

func _exit_tree() -> void:
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()

func extract(video_path: String, sample_fps: float, smooth_window: int) -> void:
	if _thread != null and _thread.is_started():
		extraction_failed.emit("Already processing — please wait.")
		return

	var script_abs: String = AIPoseClient.extract_to_disk(SCRIPT_PATH)
	if script_abs == "" or not FileAccess.file_exists(script_abs):
		extraction_failed.emit("extract_video_poses.py could not be prepared (%s)" % SCRIPT_PATH)
		return

	_thread = Thread.new()
	_thread.start(_run_in_thread.bind(video_path, script_abs, sample_fps, smooth_window))

func _run_in_thread(video_path: String, script_abs: String, sample_fps: float, smooth_window: int) -> void:
	var python := _find_python()
	if python == "":
		_result = {"error": "Python not found. Install Python 3.10+ from python.org"}
		call_deferred("_on_thread_done")
		return

	var output: Array = []
	OS.execute(python, [script_abs, video_path, str(sample_fps), str(smooth_window)], output, true, true)

	var stdout := ""
	for line in output:
		stdout += line

	var json_line := ""
	for line in stdout.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.begins_with("{"):
			json_line = trimmed

	var json := JSON.new()
	if json_line == "" or json.parse(json_line) != OK:
		_result = {"error": "Could not parse output: %s" % stdout.left(300)}
		call_deferred("_on_thread_done")
		return

	_result = json.get_data()
	call_deferred("_on_thread_done")

func _on_thread_done() -> void:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null

	if _result.has("error"):
		extraction_failed.emit(_result["error"])
	else:
		var frames: Array = _result.get("frames", [])
		var duration: float = _result.get("duration", 0.0)
		if frames.is_empty():
			extraction_failed.emit("No pose detected in any frame")
		else:
			extraction_done.emit(frames, duration)
	_result = {}

static func _find_python() -> String:
	return AIPoseClient._find_python()
