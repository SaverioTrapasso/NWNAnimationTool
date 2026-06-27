extends Panel

## Standalone retargeting panel: load a .cfg (the bone map + offsets — fully
## portable, no glb reference baked in), import the model+animation glb to
## bake, and bake it onto the NWN rig's timeline. Pure UI — main.gd owns the
## actual RetargetConfig/Retargeter calls and the result.

signal cfg_import_requested(path: String)
signal import_model_requested(path: String)
signal bake_requested(root_scale: float)
signal bone_map_debug_requested()

@onready var cfg_button: Button = $VBox/CfgRow/CfgButton
@onready var cfg_label: Label = $VBox/CfgRow/CfgLabel
@onready var import_button: Button = $VBox/ImportRow/ImportButton
@onready var source_label: Label = $VBox/ImportRow/SourceLabel
@onready var root_scale_spin: SpinBox = $VBox/RootScaleRow/RootScaleSpin
@onready var bake_button: Button = $VBox/BakeButton
@onready var status_label: Label = $VBox/StatusLabel
@onready var cfg_dialog: FileDialog = $CfgDialog
@onready var import_dialog: FileDialog = $ImportDialog
@onready var close_button: Button = $VBox/HeaderRow/CloseButton
@onready var bone_map_button: Button = $VBox/HeaderRow/BoneMapButton

func _ready() -> void:
	visible = false
	cfg_button.pressed.connect(func(): cfg_dialog.popup_centered_ratio(0.6))
	cfg_dialog.file_selected.connect(_on_cfg_file_selected)
	import_button.pressed.connect(func(): import_dialog.popup_centered_ratio(0.6))
	import_dialog.file_selected.connect(_on_import_file_selected)
	bake_button.pressed.connect(func(): bake_requested.emit(root_scale_spin.value))
	close_button.pressed.connect(func(): visible = false)
	bone_map_button.pressed.connect(func(): bone_map_debug_requested.emit())

func _on_cfg_file_selected(path: String) -> void:
	cfg_label.text = path.get_file()
	cfg_import_requested.emit(path)

func _on_import_file_selected(path: String) -> void:
	source_label.text = path.get_file()
	import_model_requested.emit(path)

func set_status(text: String) -> void:
	status_label.text = text

func set_cfg_label(text: String) -> void:
	cfg_label.text = text

func reset_import_state() -> void:
	source_label.text = "No file loaded"
	status_label.text = ""

func toggle_visible() -> void:
	visible = not visible
