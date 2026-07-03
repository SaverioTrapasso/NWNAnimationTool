## Sends an image to the local MediaPipe pose server and returns the
## world-space 3D landmarks as a Dictionary.  All network I/O is async
## (HTTPRequest node); callers connect to pose_received / pose_failed.
extends Node

signal pose_received(world_landmarks: Array)
signal pose_failed(error: String)

const SERVER_URL := "http://127.0.0.1:7842/pose"
const HEALTH_URL := "http://127.0.0.1:7842/health"

var _http: HTTPRequest

func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)

## Check if the Python server is running.
func check_server(callback: Callable) -> void:
	var h := HTTPRequest.new()
	add_child(h)
	h.request_completed.connect(func(result, code, _headers, _body):
		h.queue_free()
		callback.call(code == 200)
	)
	h.request(HEALTH_URL, [], HTTPClient.METHOD_GET)

## Send raw image bytes (PNG or JPG) to the server.
func send_image(image_bytes: PackedByteArray) -> void:
	var headers := ["Content-Type: image/png", "Content-Length: %d" % image_bytes.size()]
	var err := _http.request_raw(SERVER_URL, headers, HTTPClient.METHOD_POST, image_bytes)
	if err != OK:
		pose_failed.emit("HTTPRequest error: %d" % err)

func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		pose_failed.emit("Server error (result=%d code=%d)" % [result, response_code])
		return
	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		pose_failed.emit("Invalid JSON from server")
		return
	var data: Dictionary = json.get_data()
	var wl: Array = data.get("world_landmarks", [])
	if wl.is_empty():
		pose_failed.emit("No pose detected in image")
		return
	pose_received.emit(wl)
