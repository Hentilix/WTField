extends SceneTree

var checks: int = 0
var failures: int = 0
var audio: Node
var settings_file: String
var world: Node2D


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	audio = root.get_node_or_null("AudioManager")
	_check(audio != null, "project provides the AudioManager autoload")
	if audio == null:
		_finish()
		return
	settings_file = "res://.godot/audio_test_%d.cfg" % OS.get_process_id()
	audio.settings_path = settings_file
	audio.load_settings()
	await _test_playback()
	await _test_settings()
	await _test_gameplay_events()
	await _test_footsteps()
	await _test_settings_panel_and_restart()
	audio.stop_round()
	audio.flush_settings()
	if FileAccess.file_exists(settings_file):
		DirAccess.remove_absolute(settings_file)
	_finish()


func _test_playback() -> void:
	var music: AudioStreamPlayer = audio.get_node("Music")
	var shot: AudioStreamPlayer = audio.get_node("Shot")
	var result: AudioStreamPlayer = audio.get_node("Result")
	_check(not audio.play_sfx(&"shot"), "combat audio rejected before round starts")
	audio.start_round()
	_check(music.playing and music.stream.loop, "round starts looped Overworld music")
	_check(not audio.play_sfx(&"unknown"), "unknown cue safely rejected")
	_check(audio.play_sfx(&"shot") and shot.playing, "successful gunshot starts actual playback")
	_check(not audio.play_sfx(&"shot"), "same-frame gunshot is throttled")
	await _wait_seconds(0.075)
	_check(audio.play_sfx(&"shot"), "gunshot allowed after 60ms cooldown")
	_check(shot.max_polyphony == 2, "rapid fire playback has a two-voice bound")
	_check(audio.get_node("EnemyDeath").max_polyphony == 3, "enemy deaths have a three-voice bound")
	_check(audio.get_node("Explosion").max_polyphony == 2, "chain explosions have a two-voice bound")
	audio.set_gameplay_paused(true)
	paused = true
	_check(not shot.playing and music.playing, "settings pause stops combat but preserves music")
	_check(not audio.play_sfx(&"pickup"), "paused gameplay cannot produce sound")
	audio.preview_sfx()
	_check(audio.get_node("Preview").playing, "preview works independently of gameplay pause")
	audio.set_gameplay_paused(false)
	paused = false
	audio.finish_round(false)
	paused = true
	_check(not music.playing and result.playing, "defeat stops music and starts result while paused")
	_check(result.stream.resource_path.ends_with("cowboy_dead.wav"), "defeat uses death cue")
	await _wait_seconds(0.1)
	_check(result.playing and not result.stream_paused, "result continues through tree pause")
	audio.finish_round(true)
	_check(result.stream.resource_path.ends_with("cowboy_dead.wav"), "duplicate result cannot replace first outcome")
	_check(not audio.play_sfx(&"explosion"), "late chain explosions cannot play after result")
	paused = false
	audio.start_round()
	_check(music.playing and not result.playing and not audio.get_node("Preview").playing, "restart clears old result and preview")
	_check(music.get_playback_position() < 0.1 and audio.play_sfx(&"shot"), "restart resets music and cooldown")
	audio.finish_round(true)
	_check(result.stream.resource_path.ends_with("Cowboy_Secret.wav"), "victory uses secret cue")
	audio.stop_round()
	_check(not music.playing and not result.playing, "leaving round stops all audio")


func _test_settings() -> void:
	var music_bus := AudioServer.get_bus_index(&"Music")
	var sfx_bus := AudioServer.get_bus_index(&"SFX")
	_check(music_bus > 0 and sfx_bus > 0, "separate music and SFX buses exist")
	_check(is_equal_approx(audio.get_music_volume(), 0.6) and is_equal_approx(audio.get_sfx_volume(), 0.8), "missing settings use 60/80 defaults")
	audio.set_music_volume(0.25)
	audio.set_sfx_volume(0.0)
	_check(is_equal_approx(AudioServer.get_bus_volume_linear(music_bus), 0.25), "music volume immediately reaches its bus")
	_check(AudioServer.is_bus_mute(sfx_bus) and not AudioServer.is_bus_mute(music_bus), "zero SFX mutes only SFX")
	paused = true
	await _wait_seconds(0.4)
	var saved := ConfigFile.new()
	_check(saved.load(settings_file) == OK, "debounced settings save runs while paused")
	_check(is_equal_approx(saved.get_value("audio", "music_volume", -1.0), 0.25), "saved music volume is correct")
	paused = false
	audio.load_settings()
	_check(is_zero_approx(audio.get_sfx_volume()) and is_equal_approx(audio.get_music_volume(), 0.25), "settings round trip retains independent volumes")
	audio.set_sfx_volume(0.5)
	_check(not AudioServer.is_bus_mute(sfx_bus), "raising volume unmutes SFX")
	audio.start_round()
	_check(is_equal_approx(audio.get_music_volume(), 0.25), "new round preserves volume")
	audio.stop_round()
	saved.set_value("audio", "music_volume", "bad value")
	saved.set_value("audio", "sfx_volume", 2.0)
	saved.save(settings_file)
	audio.load_settings()
	_check(is_equal_approx(audio.get_music_volume(), 0.6) and is_equal_approx(audio.get_sfx_volume(), 1.0), "invalid field defaults while finite numeric field clamps")
	var file := FileAccess.open(settings_file, FileAccess.WRITE)
	file.store_string("[broken")
	file.close()
	audio.load_settings()
	_check(is_equal_approx(audio.get_music_volume(), 0.6) and is_equal_approx(audio.get_sfx_volume(), 0.8), "corrupt settings restore defaults")
	audio.set_music_volume(NAN)
	audio.set_sfx_volume(INF)
	_check(is_equal_approx(audio.get_music_volume(), 0.6) and is_equal_approx(audio.get_sfx_volume(), 0.8), "non-finite volume inputs cannot poison audio bus")
	audio.settings_path = "res://.godot/audio_missing_%d/settings.cfg" % OS.get_process_id()
	audio.set_music_volume(0.3)
	_check(audio.flush_settings() != OK and audio.settings_save_failed, "failed save is reported without losing live volume")
	_check(is_equal_approx(audio.get_music_volume(), 0.3), "save failure preserves current listening volume")
	audio.settings_path = settings_file
	_check(audio.flush_settings() == OK and not audio.settings_save_failed, "retry can recover settings save")


func _wait_seconds(seconds: float) -> void:
	# Cooldowns use monotonic time; the first SceneTree timer can include startup delta.
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame


func _test_gameplay_events() -> void:
	world = Node2D.new()
	root.add_child(world)
	current_scene = world
	audio.start_round()
	var player = load("res://scene/player.tscn").instantiate()
	world.add_child(player)
	player.set_physics_process(false)
	var shot: AudioStreamPlayer = audio.get_node("Shot")
	_check(not player._fire_bullets(Vector2.ZERO) and not shot.playing, "rejected shot is silent")
	player._fire_bullets(Vector2.RIGHT)
	_check(shot.playing, "actual normal shot produces gunshot")
	audio.start_round()
	player.apply_pickup(load("res://resources/config/pickup_spiral.tres"))
	player._fire_bullets(Vector2.ZERO)
	_check(shot.playing, "automatic spiral shot produces gunshot")
	player.take_damage(1)
	var hurt: AudioStreamPlayer = audio.get_node("PlayerHurt")
	_check(hurt.playing, "nonlethal player damage produces hurt audio")
	hurt.stop()
	player.take_damage(1)
	_check(not hurt.playing, "invulnerable player rejects repeat hurt sound")
	var enemy = load("res://scene/enemy.tscn").instantiate()
	enemy.config = load("res://resources/config/enemy_armored.tres")
	enemy.position = Vector2(200, 200)
	world.add_child(enemy)
	enemy.set_physics_process(false)
	enemy.take_damage(1)
	var death: AudioStreamPlayer = audio.get_node("EnemyDeath")
	_check(not death.playing and not hurt.playing, "enemy nonlethal damage remains silent")
	enemy.take_damage(100)
	_check(death.playing, "enemy lethal damage plays death cue")
	death.stop()
	await _wait_seconds(0.07)
	enemy.take_damage(100)
	_check(not death.playing, "duplicate enemy death cannot replay sound after cooldown")
	var pickup = load("res://scene/pickup.tscn").instantiate()
	world.add_child(pickup)
	pickup.position = Vector2(300, 300)
	pickup.set_physics_process(false)
	pickup._on_body_entered(player)
	var powerup: AudioStreamPlayer = audio.get_node("Pickup")
	_check(not powerup.playing, "invalid pickup is silent")
	pickup.config = load("res://resources/config/pickup_spiral.tres")
	pickup._on_body_entered(player)
	_check(powerup.playing, "successful refresh plays powerup")
	powerup.stop()
	pickup._on_body_entered(player)
	_check(not powerup.playing, "same pickup cannot sound twice")
	var fresh_pickup = load("res://scene/pickup.tscn").instantiate()
	fresh_pickup.config = load("res://resources/config/pickup_speed.tres")
	fresh_pickup.position = Vector2(300, 300)
	world.add_child(fresh_pickup)
	fresh_pickup._on_body_entered(player)
	await process_frame
	await process_frame
	_check(not is_instance_valid(fresh_pickup) and powerup.playing, "pickup tail survives source deletion")
	var explosion = load("res://scene/explosion.tscn").instantiate()
	explosion.position = Vector2(500, 500)
	world.add_child(explosion)
	explosion.detonate()
	var blast: AudioStreamPlayer = audio.get_node("Explosion")
	_check(blast.playing, "detonation produces explosion sound")
	blast.stop()
	await _wait_seconds(0.1)
	explosion.detonate()
	_check(not blast.playing, "repeat detonation stays silent after cooldown")
	var fresh_explosion = load("res://scene/explosion.tscn").instantiate()
	fresh_explosion.position = Vector2(500, 500)
	world.add_child(fresh_explosion)
	fresh_explosion.detonate()
	await _wait_seconds(0.65)
	_check(not is_instance_valid(fresh_explosion) and blast.playing, "explosion audio outlives its half-second animation")
	await _clear_world()


func _test_footsteps() -> void:
	world = Node2D.new()
	root.add_child(world)
	current_scene = world
	audio.start_round()
	var player = load("res://scene/player.tscn").instantiate()
	world.add_child(player)
	var foot: AudioStreamPlayer = audio.get_node("Footstep")
	Input.action_press("move_right")
	await _wait_seconds(0.35)
	Input.action_release("move_right")
	_check(player.position.x > 32.0 and foot.playing, "real movement produces a distance-based footstep")
	await _wait_seconds(0.3)
	_check(not foot.playing, "stationary player does not repeat footsteps")
	var wall := StaticBody2D.new()
	var shape := RectangleShape2D.new()
	shape.size = Vector2(20, 200)
	var collision := CollisionShape2D.new()
	collision.shape = shape
	wall.add_child(collision)
	wall.position = player.position + Vector2(20, 0)
	world.add_child(wall)
	Input.action_press("move_right")
	await _wait_seconds(0.7)
	_check(not foot.playing, "pressing into wall does not produce footsteps")
	Input.action_release("move_right")
	await _clear_world()


func _test_settings_panel_and_restart() -> void:
	world = load("res://scene/game.tscn").instantiate()
	root.add_child(world)
	current_scene = world
	var panel = world.get_node_or_null("HUD/AudioSettings")
	_check(panel != null, "main scene provides audio settings panel")
	_check(audio.get_node("Music").playing, "main scene starts music on entry")
	if panel == null:
		await _clear_world()
		return
	var player = world.get_node("Player")
	player.apply_pickup(load("res://resources/config/pickup_speed.tres"))
	world.get_node("EnemyDirector").advance_spawning(1.9)
	panel.get_node("SoundButton").pressed.emit()
	_check(panel.is_open() and paused, "sound button opens modal and pauses gameplay")
	var time_before: float = world.remaining_time
	var buff_before: float = player.buff_controller.get_remaining_time(0)
	var position_before: Vector2 = player.position
	var enemies_before: int = world.get_node("EnemyDirector").get_alive_count()
	Input.action_press("move_right")
	Input.action_press("shoot_right")
	await _wait_seconds(0.4)
	Input.action_release("move_right")
	Input.action_release("shoot_right")
	_check(is_equal_approx(world.remaining_time, time_before), "settings freezes countdown")
	_check(is_equal_approx(player.buff_controller.get_remaining_time(0), buff_before), "settings freezes buff duration")
	_check(player.position == position_before and not audio.get_node("Shot").playing, "settings freezes movement and firing")
	_check(world.get_node("EnemyDirector").get_alive_count() == enemies_before, "settings freezes enemy spawning")
	_check(audio.get_node("Music").playing, "music continues while adjusting settings")
	_check(panel.music_slider.has_focus(), "modal initially focuses music slider")
	_check(panel.close_button.find_next_valid_focus() == panel.music_slider, "Tab navigation stays inside modal")
	panel.sfx_slider.value = 35.0
	await _wait_seconds(0.2)
	_check(audio.get_node("Preview").playing, "completed keyboard SFX adjustment previews sound")
	panel.music_slider.value = 45.0
	panel.close_button.pressed.emit()
	_check(not paused and not panel.is_open(), "close resumes active round")
	var saved := ConfigFile.new()
	saved.load(settings_file)
	_check(is_equal_approx(saved.get_value("audio", "music_volume", -1.0), 0.45), "closing panel flushes newest settings")
	var escape := InputEventKey.new()
	escape.physical_keycode = KEY_ESCAPE
	escape.pressed = true
	Input.parse_input_event(escape)
	await process_frame
	_check(panel.is_open() and paused, "Escape opens settings via actual input routing")
	escape.pressed = false
	Input.parse_input_event(escape)
	panel.close_settings()
	paused = true
	panel.open_settings()
	panel.close_settings()
	_check(paused, "closing settings preserves an existing pause")
	paused = false
	panel.open_settings()
	world._end_game(true)
	panel.close_settings()
	_check(paused and world.is_round_over, "closing over victory never unpauses completed round")
	_check(audio.get_node("Result").playing and not audio.get_node("Music").playing, "game victory plays result during pause")
	world.get_node("HUD/GameOver/Center/Panel/Content/Restart").pressed.emit()
	await process_frame
	await process_frame
	world = current_scene
	_check(not paused and not world.is_round_over and audio.get_node("Music").playing, "restart creates active round with music")
	_check(not audio.get_node("Result").playing and is_equal_approx(audio.get_sfx_volume(), 0.35), "restart clears result but retains volume")
	player = world.get_node("Player")
	player.take_damage(100)
	_check(paused and audio.get_node("Result").stream.resource_path.ends_with("cowboy_dead.wav"), "actual player death uses one defeat cue")
	_check(not audio.get_node("PlayerHurt").playing, "fatal player damage does not layer hurt cue")
	await _clear_world()


func _clear_world() -> void:
	paused = false
	world.queue_free()
	await process_frame
	await process_frame
	current_scene = null
	audio.stop_round()


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr("FAIL: ", description)


func _finish() -> void:
	print("Audio system: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
