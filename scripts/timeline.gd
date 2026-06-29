extends Control

## A simple scrubbable timeline bar: drag anywhere to move the playhead,
## yellow dots mark saved keyframes. Emits time_changed whenever the
## playhead moves so the rig can preview the pose at that time.

signal time_changed(t: float)
## Shift+click-dragging an EXISTING keyframe dot rigidly slides it and every
## keyframe to its right by the same amount -- e.g. to squeeze out an
## unwanted opening key pose by dragging the second keyframe back toward 0.
## Emitted only while Shift is held and the click/drag started on a real
## keyframe; a Shift-click on empty track does nothing (no signal at all).
signal shift_drag_started(anchor_time: float)
signal shift_drag_moved(anchor_time: float, delta_time: float)
signal shift_drag_ended()

var length: float = 5.0
var current_time: float = 0.0
var keyframe_times: Array = []

var _dragging: bool = false
var _shift_dragging: bool = false
var _shift_anchor_time: float = 0.0
var _shift_drag_start_x: float = 0.0

const MARGIN := 14.0
const SNAP_PIXELS := 10.0

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
		if event.pressed:
			if event.shift_pressed:
				var hit = _find_keyframe_near(event.position.x)
				if hit != null:
					_shift_dragging = true
					_shift_anchor_time = hit
					_shift_drag_start_x = event.position.x
					shift_drag_started.emit(_shift_anchor_time)
					accept_event()
				# Shift-click on empty track: intentionally does nothing,
				# not even a normal scrub -- this gesture only ever means
				# "grab that keyframe," never "move the playhead."
			else:
				_dragging = true
				_scrub_to(event.position.x)
				accept_event()
		else:
			if _shift_dragging:
				_shift_dragging = false
				shift_drag_ended.emit()
				accept_event()
			elif _dragging:
				_dragging = false
				accept_event()
	elif event is InputEventMouseMotion:
		if _shift_dragging:
			var w: float = size.x - MARGIN * 2.0
			if w > 0.0:
				var delta_time: float = (event.position.x - _shift_drag_start_x) / w * length
				shift_drag_moved.emit(_shift_anchor_time, delta_time)
			accept_event()
		elif _dragging:
			_scrub_to(event.position.x)
			accept_event()

## Returns the time of the keyframe dot nearest `x` (within SNAP_PIXELS), or
## null if there's no keyframe close enough to count as "clicked on it."
func _find_keyframe_near(x: float) -> Variant:
	var w: float = size.x - MARGIN * 2.0
	if w <= 0.0:
		return null
	var best_dist := INF
	var best_time: Variant = null
	for t in keyframe_times:
		var kx: float = MARGIN + (t / length) * w
		var dist: float = abs(kx - x)
		if dist < SNAP_PIXELS and dist < best_dist:
			best_dist = dist
			best_time = t
	return best_time

func _scrub_to(x: float) -> void:
	var w: float = size.x - MARGIN * 2.0
	if w <= 0.0:
		return
	var ratio: float = clamp((x - MARGIN) / w, 0.0, 1.0)
	current_time = ratio * length

	# Snap to a nearby keyframe marker so clicking a dot precisely selects
	# it, instead of landing a fraction of a second off.
	var best_dist := INF
	var best_time := current_time
	for t in keyframe_times:
		var kx: float = MARGIN + (t / length) * w
		var dist: float = abs(kx - x)
		if dist < SNAP_PIXELS and dist < best_dist:
			best_dist = dist
			best_time = t
	current_time = best_time

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
		var selected: bool = abs(t - current_time) < 0.005
		if selected:
			draw_circle(Vector2(x, track_y), 10.0, Color(1, 1, 1))
		draw_circle(Vector2(x, track_y), 7.0, Color(0.95, 0.82, 0.15))
		draw_arc(Vector2(x, track_y), 7.0, 0, TAU, 24, Color(0.4, 0.35, 0.05), 1.5)

	var playhead_x: float = MARGIN + (current_time / length) * w
	draw_line(Vector2(playhead_x, 2.0), Vector2(playhead_x, size.y - 2.0), Color(0.85, 0.2, 0.2), 2.0)

	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(MARGIN, size.y - 4.0), "%.2fs / %.2fs" % [current_time, length],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.25, 0.25, 0.22))
