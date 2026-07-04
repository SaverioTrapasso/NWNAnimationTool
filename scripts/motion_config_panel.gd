## Floating panel exposing the AI motion-adaptation knobs that used to be
## hard-coded: world-tilt correction, hand/foot orientation offsets, feet
## height and scale. The video bake reads this panel every time it runs,
## so the workflow is: bake → inspect → tweak a knob → bake again.
##
## Every "auto" checkbox keeps the automatic first-frame computation as the
## default; unchecking it hands control to the manual fields next to it.
extends Panel

const BONES := ["rhand_g", "lhand_g", "rfoot_g", "lfoot_g"]

@onready var _auto_tilt: CheckBox = $Scroll/Rows/AutoTiltCheck
@onready var _tilt_x: SpinBox = $Scroll/Rows/TiltRow/TiltX
@onready var _tilt_z: SpinBox = $Scroll/Rows/TiltRow/TiltZ
@onready var _auto_calib: CheckBox = $Scroll/Rows/AutoCalibCheck
@onready var _offset_grid: GridContainer = $Scroll/Rows/OffsetGrid
@onready var _foot_spin: SpinBox = $Scroll/Rows/FootRow/FootSpin
@onready var _auto_scale: CheckBox = $Scroll/Rows/AutoScaleCheck
@onready var _scale_spin: SpinBox = $Scroll/Rows/ScaleRow/ScaleSpin
@onready var _readout: Label = $Scroll/Rows/ReadoutLabel

# bone name -> [SpinBox, SpinBox, SpinBox] (X, Y, Z degrees)
var _offset_spins: Dictionary = {}

func _ready() -> void:
	$TitleRow/CloseButton.pressed.connect(func(): visible = false)
	for bone in BONES:
		_offset_spins[bone] = [
			_offset_grid.get_node("%sX" % bone),
			_offset_grid.get_node("%sY" % bone),
			_offset_grid.get_node("%sZ" % bone),
		]

func toggle_visible() -> void:
	visible = not visible

# --- Ground alignment -------------------------------------------------------

func is_auto_tilt() -> bool:
	return _auto_tilt.button_pressed

## Manual world tilt in degrees around X (pitch) and Z (roll), used when
## auto tilt is off. Returns identity-equivalent (0,0) by default.
func get_manual_tilt() -> Vector2:
	return Vector2(_tilt_x.value, _tilt_z.value)

# --- Hand / foot orientation -------------------------------------------------

func is_auto_calibration() -> bool:
	return _auto_calib.button_pressed

## Extra user rotation applied on top of the (auto or absent) calibration,
## in the bone's local frame. Euler degrees from the three spinboxes.
func get_bone_offset(bone_name: String) -> Quaternion:
	var spins: Array = _offset_spins.get(bone_name, [])
	if spins.size() != 3:
		return Quaternion.IDENTITY
	return Quaternion.from_euler(Vector3(
		deg_to_rad(spins[0].value),
		deg_to_rad(spins[1].value),
		deg_to_rad(spins[2].value)))

# --- Feet / scale ------------------------------------------------------------

func get_foot_y_offset() -> float:
	return _foot_spin.value

## -1.0 means "use the automatic shoulder-width estimate".
func get_scale_override() -> float:
	return -1.0 if _auto_scale.button_pressed else _scale_spin.value

# --- Feedback ----------------------------------------------------------------

## Shows what the last bake actually computed (tilt angle, scale...), so the
## user can judge whether auto values are sane before overriding them.
func set_readout(text: String) -> void:
	_readout.text = text
