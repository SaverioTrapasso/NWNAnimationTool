class_name BoneSearchDropdown
extends Button

## Drop-in replacement for an OptionButton row in the Bone Configuration
## table, except it shows a text filter before the list: type any part of
## a bone name and the popup narrows down to matches as you type. Plain
## OptionButton has no built-in way to do this, hence the custom popup.

signal value_changed(value: String)

const UNMAPPED_LABEL := "(unmapped)"

var _all_items: Array = []
var _selected_value: String = ""

var _popup: PopupPanel
var _search: LineEdit
var _list: ItemList

func _ready() -> void:
	clip_text = true
	alignment = HORIZONTAL_ALIGNMENT_LEFT
	# NOT setting `text` here: the caller (retarget_debug_panel.gd) builds a
	# whole row off-tree and calls set_items() before add_child()-ing the
	# row into rows_container -- so _ready() actually runs AFTER set_items()
	# in that case, and unconditionally setting text here would clobber
	# whatever set_items() already wrote.
	if _all_items.is_empty() and _selected_value == "":
		text = UNMAPPED_LABEL
	pressed.connect(_open_popup)

	_popup = PopupPanel.new()
	add_child(_popup)
	var vbox := VBoxContainer.new()
	_popup.add_child(vbox)

	_search = LineEdit.new()
	_search.placeholder_text = "Filter bones..."
	_search.custom_minimum_size = Vector2(240, 0)
	vbox.add_child(_search)

	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(240, 220)
	_list.allow_reselect = true
	vbox.add_child(_list)

	_search.text_changed.connect(_on_search_changed)
	_search.gui_input.connect(_on_search_gui_input)
	_list.item_selected.connect(_on_item_chosen)
	_list.item_activated.connect(_on_item_chosen)

## names: every selectable source bone name. selected_value: the currently
## mapped bone, or "" if unmapped (still added to the list if it isn't
## among `names`, e.g. loaded from a .cfg made against a different source).
func set_items(names: Array, selected_value: String) -> void:
	_all_items = names.duplicate()
	_selected_value = selected_value
	if selected_value != "" and not _all_items.has(selected_value):
		_all_items.append(selected_value)
	text = selected_value if selected_value != "" else UNMAPPED_LABEL

func get_selected_value() -> String:
	return _selected_value

func _open_popup() -> void:
	_search.text = ""
	_refresh_list("")
	var rect := Rect2(get_screen_position() + Vector2(0, size.y), Vector2(maxf(240.0, size.x), 240.0))
	_popup.popup_on_parent(rect)
	_search.grab_focus()

func _refresh_list(filter: String) -> void:
	_list.clear()
	var unmapped_idx := _list.add_item(UNMAPPED_LABEL)
	_list.set_item_metadata(unmapped_idx, "")
	var needle := filter.to_lower()
	for n in _all_items:
		if needle == "" or String(n).to_lower().contains(needle):
			var idx := _list.add_item(n)
			_list.set_item_metadata(idx, n)
	# Default the highlighted row to the first actual match rather than the
	# leading "(unmapped)" entry, so pressing Enter right after typing a
	# filter confirms the bone you were looking for, not "unmapped".
	if _list.item_count > 1:
		_list.select(1)
	elif _list.item_count > 0:
		_list.select(0)

func _on_search_changed(new_text: String) -> void:
	_refresh_list(new_text)

func _on_search_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
			var selected := _list.get_selected_items()
			_confirm_index(selected[0] if selected.size() > 0 else 0)
			accept_event()
		elif event.keycode == KEY_ESCAPE:
			_popup.hide()
			accept_event()
		elif event.keycode == KEY_DOWN:
			_move_selection(1)
			accept_event()
		elif event.keycode == KEY_UP:
			_move_selection(-1)
			accept_event()

func _move_selection(delta: int) -> void:
	if _list.item_count == 0:
		return
	var selected := _list.get_selected_items()
	var current: int = selected[0] if selected.size() > 0 else 0
	var next: int = clampi(current + delta, 0, _list.item_count - 1)
	_list.select(next)
	_list.ensure_current_is_visible()

func _on_item_chosen(index: int) -> void:
	_confirm_index(index)

func _confirm_index(index: int) -> void:
	if index < 0 or index >= _list.item_count:
		return
	var value: String = String(_list.get_item_metadata(index))
	_selected_value = value
	text = value if value != "" else UNMAPPED_LABEL
	_popup.hide()
	value_changed.emit(value)
