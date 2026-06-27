extends Panel

## Standalone retargeting panel: load the animation to bake, and Bake.
## Configuring the bone map (associate-bone table + rotation offsets) happens
## in the separate "Configure rig" panel (opened from here).

signal load_animation_requested(path: String)
signal bake_requested()
signal bone_map_debug_requested()

@onready var load_animation_button: Button = $VBox/LoadAnimRow/LoadAnimButton
@onready var animation_label: Label = $VBox/LoadAnimRow/AnimationLabel
@onready var load_animation_dialog: FileDialog = $LoadAnimationDialog
@onready var bake_button: Button = $VBox/BakeButton
@onready var status_label: Label = $VBox/StatusLabel
@onready var close_button: Button = $VBox/HeaderRow/CloseButton
@onready var bone_map_button: Button = $VBox/HeaderRow/BoneMapButton

func _ready() -> void:
	visible = false
	load_animation_button.pressed.connect(func(): load_animation_dialog.popup_centered_ratio(0.6))
	load_animation_dialog.file_selected.connect(func(path): load_animation_requested.emit(path))
	bake_button.pressed.connect(func(): bake_requested.emit())
	close_button.pressed.connect(func(): visible = false)
	bone_map_button.pressed.connect(func(): bone_map_debug_requested.emit())

func set_animation_label(text: String) -> void:
	animation_label.text = text

func set_status(text: String) -> void:
	status_label.text = text

func toggle_visible() -> void:
	visible = not visible
