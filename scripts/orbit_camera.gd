extends Camera3D

## Simple orbit/pan/zoom camera for inspecting the rig.
## Right mouse drag orbits, middle mouse drag pans, wheel zooms.

@export var target: Vector3 = Vector3(0, 1.0, 0)
@export var distance: float = 3.0
@export var min_distance: float = 0.5
@export var max_distance: float = 10.0
@export var orbit_speed: float = 0.01
@export var pan_speed: float = 0.002
@export var zoom_speed: float = 0.2

var yaw: float = PI # start facing the character's front instead of its back
var pitch: float = -0.3
var _orbiting: bool = false
var _panning: bool = false

func _ready() -> void:
	_update_transform()

func _update_transform() -> void:
	var rot_basis := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch)
	var offset := rot_basis * Vector3(0, 0, distance)
	global_position = target + offset
	look_at(target, Vector3.UP)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_orbiting = event.pressed
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = clamp(distance - zoom_speed, min_distance, max_distance)
			_update_transform()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance = clamp(distance + zoom_speed, min_distance, max_distance)
			_update_transform()
	elif event is InputEventMouseMotion:
		if _orbiting:
			yaw -= event.relative.x * orbit_speed
			pitch = clamp(pitch - event.relative.y * orbit_speed, -1.5, 1.5)
			_update_transform()
		elif _panning:
			var right := global_transform.basis.x
			var up := global_transform.basis.y
			target -= right * event.relative.x * pan_speed
			target += up * event.relative.y * pan_speed
			_update_transform()
