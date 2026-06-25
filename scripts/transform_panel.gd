extends Panel

## Always-visible (while something is selected) readout/editor for the
## current component's position and rotation, since grabbing the exact
## angle/offset with the gizmo alone is fiddly. Two-way synced: dragging the
## gizmo updates these fields, and typing in a field moves the gizmo/rig.

signal position_changed(v: Vector3)
signal rotation_changed(v: Vector3) # degrees

@onready var component_label: Label = $HBox/ComponentLabel
@onready var pos_x: SpinBox = $HBox/PosBox/PosRow/PosX
@onready var pos_y: SpinBox = $HBox/PosBox/PosRow/PosY
@onready var pos_z: SpinBox = $HBox/PosBox/PosRow/PosZ
@onready var rot_x: SpinBox = $HBox/RotBox/RotRow/RotX
@onready var rot_y: SpinBox = $HBox/RotBox/RotRow/RotY
@onready var rot_z: SpinBox = $HBox/RotBox/RotRow/RotZ

var _updating: bool = false

func _ready() -> void:
	visible = false
	for sb in [pos_x, pos_y, pos_z]:
		sb.value_changed.connect(_on_position_field_changed)
	for sb in [rot_x, rot_y, rot_z]:
		sb.value_changed.connect(_on_rotation_field_changed)

func _on_position_field_changed(_value: float) -> void:
	if _updating:
		return
	position_changed.emit(Vector3(pos_x.value, pos_y.value, pos_z.value))

func _on_rotation_field_changed(_value: float) -> void:
	if _updating:
		return
	rotation_changed.emit(Vector3(rot_x.value, rot_y.value, rot_z.value))

func set_label(text: String) -> void:
	component_label.text = text

func set_position_fields(v: Vector3) -> void:
	_updating = true
	pos_x.set_value_no_signal(v.x)
	pos_y.set_value_no_signal(v.y)
	pos_z.set_value_no_signal(v.z)
	_updating = false

func set_rotation_fields(v: Vector3) -> void:
	_updating = true
	rot_x.set_value_no_signal(v.x)
	rot_y.set_value_no_signal(v.y)
	rot_z.set_value_no_signal(v.z)
	_updating = false

func set_position_enabled(enabled: bool) -> void:
	pos_x.editable = enabled
	pos_y.editable = enabled
	pos_z.editable = enabled
	$HBox/PosBox.modulate.a = 1.0 if enabled else 0.35

## True if the user is actively typing in one of the fields — used to avoid
## stomping their input with the per-frame live-sync from the gizmo.
func any_field_focused() -> bool:
	for sb in [pos_x, pos_y, pos_z, rot_x, rot_y, rot_z]:
		if sb.get_line_edit().has_focus():
			return true
	return false
