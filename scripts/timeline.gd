extends Control

## A simple scrubbable timeline bar: drag anywhere to move the playhead,
## yellow dots mark saved keyframes. Emits time_changed whenever the
## playhead moves so the rig can preview the pose at that time.

signal time_changed(t: float)

var length: float = 5.0
var current_time: float = 0.0
var keyframe_times: Array = []

var _dragging: bool = false

const MARGIN := 14.0

func _ready() -> void:
	custom_minimum_size = Vector2(0, 56)
	mouse_filter = Control.MOUSE_FILTER_STOP

func set_length(l: float) -> void:
	length = max(l, 0.01)
	current_time = clamp(current_time, 0.0, length)
	queue_redraw()

func set_keyframe_times(times: Array) -> void:
	keyframe_times = times.duplicate()
	queue_redraw()

func set_current_time(t: float) -> void:
	current_time = clamp(t, 0.0, length)
	queue_redraw()

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		if event.pressed:
			_scrub_to(event.position.x)
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		_scrub_to(event.position.x)
		accept_event()

func _scrub_to(x: float) -> void:
	var w: float = size.x - MARGIN * 2.0
	if w <= 0.0:
		return
	var ratio: float = clamp((x - MARGIN) / w, 0.0, 1.0)
	current_time = ratio * length
	queue_redraw()
	time_changed.emit(current_time)

func _draw() -> void:
	var w: float = size.x - MARGIN * 2.0
	if w <= 0.0:
		return
	var track_y: float = size.y * 0.5
	draw_line(Vector2(MARGIN, track_y), Vector2(MARGIN + w, track_y), Color(0.55, 0.55, 0.52), 3.0)

	for t in keyframe_times:
		var x: float = MARGIN + (t / length) * w
		draw_circle(Vector2(x, track_y), 7.0, Color(0.95, 0.82, 0.15))
		draw_arc(Vector2(x, track_y), 7.0, 0, TAU, 24, Color(0.4, 0.35, 0.05), 1.5)

	var playhead_x: float = MARGIN + (current_time / length) * w
	draw_line(Vector2(playhead_x, 2.0), Vector2(playhead_x, size.y - 2.0), Color(0.85, 0.2, 0.2), 2.0)

	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(MARGIN, size.y - 4.0), "%.2fs / %.2fs" % [current_time, length],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.25, 0.25, 0.22))
