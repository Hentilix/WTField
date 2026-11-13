extends Node

signal volume_changed
signal settings_save_state_changed(failed: bool)

const DEFAULT_MUSIC_VOLUME := 0.6
const DEFAULT_SFX_VOLUME := 0.8
const WIN_SOUND := preload("res://resources/audio/Cowboy_Secret.wav")
const LOSS_SOUND := preload("res://resources/audio/cowboy_dead.wav")
const COOLDOWN_MS := {
	&"shot": 60, &"footstep": 180, &"enemy_death": 50,
	&"explosion": 80, &"pickup": 0, &"player_hurt": 0,
}

@export var settings_path: String = "user://audio_settings.cfg"

var settings_save_failed: bool = false
var _music_volume: float = DEFAULT_MUSIC_VOLUME
var _sfx_volume: float = DEFAULT_SFX_VOLUME
var _round_active: bool = false
var _gameplay_paused: bool = false
var _settings_dirty: bool = false
var _last_play_ms: Dictionary = {}

@onready var music: AudioStreamPlayer = $Music
@onready var result: AudioStreamPlayer = $Result
@onready var preview: AudioStreamPlayer = $Preview
@onready var save_timer: Timer = $SaveTimer
@onready var _players: Dictionary = {
	&"shot": $Shot, &"footstep": $Footstep, &"enemy_death": $EnemyDeath,
	&"explosion": $Explosion, &"pickup": $Pickup, &"player_hurt": $PlayerHurt,
}


func _ready() -> void:
	# Keep the original imported music usable without looping in other contexts.
	var looped_music := music.stream.duplicate() as AudioStreamMP3
	looped_music.loop = true
	music.stream = looped_music
	save_timer.timeout.connect(flush_settings)
	load_settings()


func start_round() -> void:
	stop_round()
	_round_active = true
	music.play()


func finish_round(won: bool) -> void:
	if not _round_active:
		return
	_round_active = false
	_gameplay_paused = true
	_stop_combat()
	music.stop()
	preview.stop()
	result.stop()
	_last_play_ms.clear()
	result.stream = WIN_SOUND if won else LOSS_SOUND
	result.play()


func stop_round() -> void:
	_round_active = false
	_gameplay_paused = false
	_stop_combat()
	music.stop()
	result.stop()
	preview.stop()
	_last_play_ms.clear()


func set_gameplay_paused(value: bool) -> void:
	_gameplay_paused = value
	if value:
		_stop_combat()


func play_sfx(cue: StringName) -> bool:
	if not _round_active or _gameplay_paused or not _players.has(cue):
		return false
	var now := Time.get_ticks_msec()
	if _last_play_ms.has(cue) and now - int(_last_play_ms[cue]) < int(COOLDOWN_MS[cue]):
		return false
	_last_play_ms[cue] = now
	(_players[cue] as AudioStreamPlayer).play()
	return true


func preview_sfx() -> void:
	preview.play()


func _stop_combat() -> void:
	for player: AudioStreamPlayer in _players.values():
		player.stop()


func get_music_volume() -> float:
	return _music_volume


func get_sfx_volume() -> float:
	return _sfx_volume


func set_music_volume(value: float) -> void:
	if not is_finite(value):
		return
	value = clampf(value, 0.0, 1.0)
	if is_equal_approx(value, _music_volume):
		return
	_music_volume = value
	_volume_updated()


func set_sfx_volume(value: float) -> void:
	if not is_finite(value):
		return
	value = clampf(value, 0.0, 1.0)
	if is_equal_approx(value, _sfx_volume):
		return
	_sfx_volume = value
	_volume_updated()


func _volume_updated() -> void:
	_apply_volumes()
	_settings_dirty = true
	save_timer.start()
	volume_changed.emit()


func _apply_volumes() -> void:
	for entry in [[&"Music", _music_volume], [&"SFX", _sfx_volume]]:
		var index := AudioServer.get_bus_index(entry[0])
		if index < 0:
			continue
		AudioServer.set_bus_mute(index, entry[1] == 0.0)
		# Muting handles zero without passing it through a logarithm.
		AudioServer.set_bus_volume_linear(index, maxf(entry[1], 0.0001))


func load_settings() -> void:
	save_timer.stop()
	_settings_dirty = false
	var config := ConfigFile.new()
	if config.load(settings_path) != OK:
		config.clear()
	_music_volume = _read_volume(config, "music_volume", DEFAULT_MUSIC_VOLUME)
	_sfx_volume = _read_volume(config, "sfx_volume", DEFAULT_SFX_VOLUME)
	_apply_volumes()
	_set_save_failed(false)
	volume_changed.emit()


func _read_volume(config: ConfigFile, key: String, fallback: float) -> float:
	var value: Variant = config.get_value("audio", key, fallback)
	if (value is float or value is int) and is_finite(float(value)):
		return clampf(float(value), 0.0, 1.0)
	return fallback


func flush_settings() -> Error:
	save_timer.stop()
	if not _settings_dirty:
		return OK
	var config := ConfigFile.new()
	config.set_value("audio", "music_volume", _music_volume)
	config.set_value("audio", "sfx_volume", _sfx_volume)
	var error := config.save(settings_path)
	_settings_dirty = error != OK
	_set_save_failed(error != OK)
	return error


func _set_save_failed(failed: bool) -> void:
	settings_save_failed = failed
	settings_save_state_changed.emit(failed)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		flush_settings()


func _exit_tree() -> void:
	flush_settings()
