extends Control

signal opened
signal closed

var _previous_focus: Control
var _dragging_sfx: bool = false

@onready var _audio: Node = get_node("/root/AudioManager")
@onready var sound_button: Button = $SoundButton
@onready var modal: ColorRect = $Modal
@onready var music_slider: HSlider = $Modal/Center/Panel/Content/MusicSlider
@onready var sfx_slider: HSlider = $Modal/Center/Panel/Content/SFXSlider
@onready var music_value: Label = $Modal/Center/Panel/Content/MusicHeading/Value
@onready var sfx_value: Label = $Modal/Center/Panel/Content/SFXHeading/Value
@onready var close_button: Button = $Modal/Center/Panel/Content/Close
@onready var status_label: Label = $Modal/Center/Panel/Content/SaveStatus
@onready var preview_timer: Timer = $PreviewTimer


func _ready() -> void:
	sound_button.pressed.connect(open_settings)
	close_button.pressed.connect(close_settings)
	music_slider.value_changed.connect(_on_music_changed)
	sfx_slider.value_changed.connect(_on_sfx_changed)
	sfx_slider.drag_started.connect(_on_sfx_drag_started)
	sfx_slider.drag_ended.connect(_on_sfx_drag_ended)
	preview_timer.timeout.connect(_audio.preview_sfx)
	_audio.volume_changed.connect(_sync_controls)
	_audio.settings_save_state_changed.connect(_on_save_state_changed)
	_sync_controls()
	_on_save_state_changed(_audio.settings_save_failed)


func _input(event: InputEvent) -> void:
	if event.is_action_pressed(&"toggle_audio_settings"):
		if is_open():
			close_settings()
		else:
			open_settings()
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"toggle_audio_settings"):
		if is_open():
			close_settings()
		else:
			open_settings()
		get_viewport().set_input_as_handled()


func is_open() -> bool:
	return modal.visible


func open_settings() -> void:
	if is_open():
		return
	_previous_focus = get_viewport().gui_get_focus_owner()
	sound_button.disabled = true
	modal.show()
	opened.emit()
	music_slider.grab_focus()


func close_settings() -> void:
	if not is_open():
		return
	preview_timer.stop()
	_dragging_sfx = false
	_audio.flush_settings()
	modal.hide()
	sound_button.disabled = false
	if is_instance_valid(_previous_focus) and _previous_focus.is_visible_in_tree():
		_previous_focus.grab_focus()
	else:
		sound_button.grab_focus()
	closed.emit()


func _sync_controls() -> void:
	music_slider.set_value_no_signal(roundf(_audio.get_music_volume() * 100.0))
	sfx_slider.set_value_no_signal(roundf(_audio.get_sfx_volume() * 100.0))
	music_value.text = "%d%%" % int(music_slider.value)
	sfx_value.text = "%d%%" % int(sfx_slider.value)


func _on_music_changed(value: float) -> void:
	_audio.set_music_volume(value / 100.0)


func _on_sfx_changed(value: float) -> void:
	_audio.set_sfx_volume(value / 100.0)
	if not _dragging_sfx:
		preview_timer.start()


func _on_sfx_drag_started() -> void:
	_dragging_sfx = true
	preview_timer.stop()


func _on_sfx_drag_ended(changed: bool) -> void:
	_dragging_sfx = false
	if changed:
		_audio.preview_sfx()


func _on_save_state_changed(failed: bool) -> void:
	status_label.visible = failed


func _exit_tree() -> void:
	_audio.flush_settings()
