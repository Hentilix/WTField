extends SceneTree

const CONFIG = preload("res://resources/config/pickup_config.gd")
const CONTROLLER_PATH := "res://scene/buff_controller.gd"

var failures: int = 0
var checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if not FileAccess.file_exists(CONTROLLER_PATH):
		_check(false, "BuffController must exist to apply and expire buffs")
		_finish()
		return
	_test_controller()
	await _test_integration()
	await _test_spiral_pattern()
	await _test_pickup_lifetime()
	await _test_project_physics()
	_finish()


func _test_controller() -> void:
	var controller = load(CONTROLLER_PATH).new()
	var changes: Array[int] = [0]
	controller.effects_changed.connect(func(): changes[0] += 1)
	var speed := _config(0, 5.0, 1.5, 1.0)
	var rapid := _config(1, 3.0, 1.0, 2.0)
	var spiral := _config(2, 4.0, 1.0, 2.0)
	_check(controller.apply_pickup(speed), "speed is accepted")
	_close(controller.move_speed_multiplier, 1.5, "speed applies immediately")
	controller.tick(2.0)
	_close(controller.get_remaining_time(0), 3.0, "time advances")
	_check(controller.apply_pickup(speed), "repeated speed is accepted")
	_close(controller.get_remaining_time(0), 5.0, "repeat refreshes full duration")
	_close(controller.move_speed_multiplier, 1.5, "repeat does not stack strength")
	_check(changes[0] == 2, "apply and refresh both notify consumers")
	controller.apply_pickup(rapid)
	controller.apply_pickup(spiral)
	_close(controller.rapid_fire_rate_multiplier * controller.form_fire_rate_multiplier, 4.0, "rapid and spiral multiply")
	_check(controller.player_form_mode == 1 and controller.shot_pattern == 1, "spiral enables armed form and pattern")
	controller.tick(3.0)
	_close(controller.rapid_fire_rate_multiplier, 1.0, "rapid expires independently")
	_close(controller.form_fire_rate_multiplier, 2.0, "spiral survives rapid expiry")
	_close(controller.move_speed_multiplier, 1.5, "speed survives rapid expiry")
	controller.tick(1.0)
	_check(controller.player_form_mode == 0 and controller.shot_pattern == 0, "spiral expiry restores normal form and pattern")
	_close(controller.get_remaining_time(0), 1.0, "speed retains its own remaining time")
	controller.tick(1.0)
	_close(controller.move_speed_multiplier, 1.0, "speed expiry restores baseline")
	_close(speed.duration, 5.0, "shared config duration is never mutated")
	_close(speed.get("move_speed_multiplier"), 1.5, "shared config strength is never mutated")
	for i in range(20):
		controller.apply_pickup(speed)
		controller.tick(0.1)
	_close(controller.move_speed_multiplier, 1.5, "many refreshes cannot drift strength")
	controller.clear_buffs()
	_close(controller.move_speed_multiplier, 1.0, "clear restores speed")
	_close(controller.get_remaining_time(0), 0.0, "clear removes timers")
	controller.apply_pickup(speed)
	speed.set("move_speed_multiplier", 3.0)
	controller.apply_pickup(rapid)
	_close(controller.move_speed_multiplier, 1.5, "active buff keeps a snapshot of shared config")
	speed.set("move_speed_multiplier", 1.5)
	_check(not controller.apply_pickup(_config(0, 0.0)), "invalid replacement is rejected")
	_close(controller.get_remaining_time(0), 5.0, "invalid replacement preserves valid buff")
	controller.tick(-1.0)
	_close(controller.get_remaining_time(0), 5.0, "negative delta cannot extend timers")
	controller.apply_pickup(_config(1, 5.0, 1.0, 2.0))
	controller.apply_pickup(_config(2, 5.0, 1.0, 2.0))
	controller.tick(10.0)
	_close(controller.move_speed_multiplier, 1.0, "large tick expires all buffs")
	_close(controller.rapid_fire_rate_multiplier * controller.form_fire_rate_multiplier, 1.0, "same-frame expiry resets both fire multipliers")
	_check(not controller.apply_pickup(null), "null config is rejected")
	for invalid in [_config(0, 0.0), _config(0, -1.0), _config(0, 5.0, 0.0), _config(1, 5.0, 1.0, -1.0), _config(0, NAN), _config(0, 5.0, INF)]:
		_check(not controller.apply_pickup(invalid), "invalid duration/multiplier is rejected")
	_close(controller.get_remaining_time(0), 0.0, "invalid configs leave no state")
	controller.free()
	var fresh = load(CONTROLLER_PATH).new()
	_close(fresh.move_speed_multiplier, 1.0, "new controller has no old state")
	fresh.free()


func _test_integration() -> void:
	var player = load("res://scene/player.tscn").instantiate()
	if not player.has_node("BuffController") or not player.has_node("ShootingTimer"):
		_check(false, "standalone player must contain BuffController and ShootingTimer")
		player.free()
		return
	if not FileAccess.file_exists("res://scene/pickup.tscn"):
		_check(false, "reusable pickup scene must exist")
		player.free()
		return
	var world := Node2D.new()
	root.add_child(world)
	current_scene = world
	world.add_child(player)
	player.set_physics_process(false)
	player.position = Vector2(100, 100)
	var speed: Resource = load("res://resources/config/pickup_speed.tres")
	var rapid: Resource = load("res://resources/config/pickup_rapid.tres")
	var spiral: Resource = load("res://resources/config/pickup_spiral.tres")
	_check(speed.get("icon_texture") != null and rapid.get("icon_texture") != null and spiral.get("icon_texture") != null, "all configs provide icons")
	_check(player.apply_pickup(speed), "player accepts pickup")
	await physics_frame
	Input.action_press("move_right")
	player._physics_process(0.0)
	Input.action_release("move_right")
	_close(player.velocity.x, 180.0, "speed buff affects actual player movement")
	_close(player.move_speed, 120.0, "base movement remains unchanged")
	player.shooting_timer.start(0.12)
	player.apply_pickup(rapid)
	_close(player.shooting_timer.time_left, 0.12, "pickup preserves running cooldown")
	player.apply_pickup(spiral)
	_close(player._get_effective_fire_interval(), 0.0225, "combined buffs change actual fire interval")
	_check(player.armed_effect_sprite.visible and player.body_sprite.animation == &"armed_right", "spiral immediately updates visuals")
	_check(player._fire_bullets(Vector2.ZERO), "spiral can fire without directional input")
	var phase: float = player.spiral_phase
	_check(phase > 0.0, "spiral shot advances phase")
	player.apply_pickup(spiral)
	_close(player.spiral_phase, phase, "refresh keeps spiral phase continuous")
	player.apply_pickup(speed)
	player.apply_pickup(rapid)
	_check(player.current_shot_pattern == 1 and player.current_form_mode == 1, "ordinary buffs do not override spiral")
	var bullets_before: int = _count_bullets(world)
	player.buff_controller.tick(5.0)
	_check(player.current_shot_pattern == 0 and not player.armed_effect_sprite.visible, "expiry restores normal behavior and visuals")
	_close(player._get_effective_fire_interval(), 0.18, "all expiry restores base fire interval")
	player.apply_pickup(_config(1, 5.0, 1.0, 0.005))
	_close(player._get_effective_fire_interval(), 36.0, "validated small positive fire multiplier is honored")
	player.buff_controller.clear_buffs()
	_check(_count_bullets(world) == bullets_before, "expiry leaves existing bullets alive")
	player.apply_pickup(spiral)
	_close(player.spiral_phase, 0.0, "re-entering spiral resets phase")
	player.buff_controller.clear_buffs()
	player.apply_pickup(speed)
	var paused_time: float = player.buff_controller.get_remaining_time(0)
	player.set_physics_process(true)
	paused = true
	await create_timer(0.05, true).timeout
	_close(player.buff_controller.get_remaining_time(0), paused_time, "pause freezes buff countdown")
	paused = false
	player.set_physics_process(false)
	player.buff_controller.clear_buffs()
	var pickup_scene: PackedScene = load("res://scene/pickup.tscn")
	var pickup = pickup_scene.instantiate()
	pickup.config = speed
	pickup.position = Vector2(200, 100)
	world.add_child(pickup)
	_check(pickup.get_node("Sprite2D").texture == speed.get("icon_texture"), "pickup uses configured icon")
	var changes: Array[int] = [0]
	player.buff_controller.effects_changed.connect(func(): changes[0] += 1)
	pickup._on_body_entered(player)
	pickup._on_body_entered(player)
	_check(changes[0] == 1 and pickup.is_queued_for_deletion(), "one pickup applies only once before deferred deletion")
	var invalid_pickup = pickup_scene.instantiate()
	invalid_pickup.config = _config(0, 0.0)
	invalid_pickup.position = Vector2(200, 120)
	world.add_child(invalid_pickup)
	invalid_pickup._on_body_entered(player)
	_check(not invalid_pickup.is_queued_for_deletion(), "invalid pickup is not consumed")
	invalid_pickup.queue_free()
	var empty_pickup = pickup_scene.instantiate()
	world.add_child(empty_pickup)
	empty_pickup._on_body_entered(player)
	_check(not empty_pickup.is_queued_for_deletion(), "unconfigured pickup is not consumed")
	empty_pickup.queue_free()
	var ignored_pickup = pickup_scene.instantiate()
	ignored_pickup.config = rapid
	world.add_child(ignored_pickup)
	var non_player := StaticBody2D.new()
	ignored_pickup._on_body_entered(non_player)
	_check(not ignored_pickup.is_queued_for_deletion(), "non-player bodies cannot collect pickups")
	non_player.free()
	ignored_pickup.queue_free()
	player.buff_controller.clear_buffs()
	var overlap = pickup_scene.instantiate()
	overlap.config = rapid
	overlap.position = player.position
	world.add_child(overlap)
	for i in range(4):
		await physics_frame
	await process_frame
	_check(not is_instance_valid(overlap), "real collision collects pickup")
	_close(player.rapid_fire_rate_multiplier, 2.0, "real collision applies buff to player")
	player.free()
	var fresh = load("res://scene/player.tscn").instantiate()
	world.add_child(fresh)
	fresh.set_physics_process(false)
	_close(fresh.buff_controller.get_remaining_time(1), 0.0, "recreated player has no old timers")
	_close(fresh._get_effective_fire_interval(), 0.18, "recreated player has base fire interval")
	world.queue_free()
	await process_frame
	current_scene = null


func _test_spiral_pattern() -> void:
	var world := Node2D.new()
	root.add_child(world)
	current_scene = world
	var player = load("res://scene/player.tscn").instantiate()
	world.add_child(player)
	player.set_physics_process(false)
	player.position = Vector2(128, 128)
	var spiral: Resource = load("res://resources/config/pickup_spiral.tres")
	player.apply_pickup(spiral)
	_close(player._get_effective_fire_interval(), 0.045, "spiral alone fires at quadruple normal rate")
	for degrees in [0, 30, 60, 90, 120, 150, 180, 210, 240, 270, 300, 330]:
		var before := _count_bullets(world)
		player._fire_bullets(Vector2.ZERO)
		_check(_count_bullets(world) == before + 1, "spiral remains a single stream")
		var bullet: Bullet = world.get_child(world.get_child_count() - 1)
		_check(bullet.direction.is_equal_approx(Vector2.RIGHT.rotated(deg_to_rad(degrees))), "spiral shot direction is %s degrees" % degrees)
	_check(Vector2.RIGHT.rotated(player.spiral_phase).is_equal_approx(Vector2.RIGHT), "twelve spiral shots complete a full rotation")
	player.shooting_timer.start(0.12)
	var phase: float = player.spiral_phase
	player.apply_pickup(spiral)
	_close(player.shooting_timer.time_left, 0.12, "spiral refresh preserves active shooting cooldown")
	_close(player.spiral_phase, phase, "spiral refresh preserves phase after a full rotation")
	player.apply_pickup(load("res://resources/config/pickup_rapid.tres"))
	_close(player._get_effective_fire_interval(), 0.0225, "rapid pickup still multiplies spiral fire rate")
	player.buff_controller.tick(5.0)
	_close(player._get_effective_fire_interval(), 0.18, "spiral expiry restores normal firing rate")
	player.apply_pickup(spiral)
	_close(player.spiral_phase, 0.0, "re-entering spiral resets phase")
	world.queue_free()
	await process_frame
	current_scene = null


func _test_project_physics() -> void:
	var game = load("res://scene/game.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	var player = game.get_node("Player")
	player.set_physics_process(false)
	_check(_count_pickups(game) == 0, "main scene starts without ground pickups")
	for i in range(4):
		await physics_frame
	_check(_count_pickups(game) == 0, "main scene does not automatically spawn pickups")
	# 地图拾取验证自行创建测试道具，正式场景不再放置演示实例。
	var demos: Array = []
	for type_name in ["speed", "rapid", "spiral"]:
		var pickup = load("res://scene/pickup.tscn").instantiate()
		pickup.config = load("res://resources/config/pickup_%s.tres" % type_name)
		pickup.position = Vector2(64 + demos.size() * 32, 64)
		game.add_child(pickup)
		demos.append(pickup)
	for pickup in demos:
		var pickup_type: int = pickup.config.pickup_type
		player.global_position = pickup.global_position
		for i in range(4):
			await physics_frame
		await process_frame
		_check(not is_instance_valid(pickup), "demo pickup %d can be collected on the actual map" % pickup_type)
		_check(player.buff_controller.get_remaining_time(pickup_type) > 0.0, "map pickup %d activates correct buff" % pickup_type)
	player.shooting_timer.stop()
	player.set_physics_process(true)
	for i in range(5):
		await physics_frame
	await process_frame
	_check(_count_bullets(game) > 0 and player.spiral_phase > 0.0, "spiral fires automatically in real physics frames")
	player.buff_controller.clear_buffs()
	player.global_position = Vector2(24, 40)
	Input.action_press("move_left")
	for i in range(24):
		await physics_frame
	Input.action_release("move_left")
	_check(player.global_position.x >= 21.9 and player.global_position.x < 24.0, "player collides with visible outer wall (x=%s)" % player.global_position.x)
	player.set_physics_process(false)
	var bullet_scene: PackedScene = load("res://scene/bullet.tscn")
	var wall_bullet = bullet_scene.instantiate()
	game.add_child(wall_bullet)
	wall_bullet.position = Vector2(240, 40)
	wall_bullet.setup(Vector2.RIGHT)
	_close(wall_bullet.speed, 320.0, "bullet scene uses default movement speed")
	_close(wall_bullet.max_lifetime, 2.0, "bullet scene uses default lifetime")
	for i in range(12):
		await physics_frame
	await process_frame
	_check(not is_instance_valid(wall_bullet), "bullet is cleaned up on world collision")
	var timed_bullet = bullet_scene.instantiate()
	timed_bullet.max_lifetime = 0.05
	game.add_child(timed_bullet)
	timed_bullet.position = Vector2(96, 40)
	timed_bullet.setup(Vector2.RIGHT)
	for i in range(8):
		await physics_frame
	await process_frame
	_check(not is_instance_valid(timed_bullet), "bullet expires without hitting a target")
	game.queue_free()
	await process_frame
	current_scene = null


func _test_pickup_lifetime() -> void:
	var world := Node2D.new()
	root.add_child(world)
	var player = load("res://scene/player.tscn").instantiate()
	world.add_child(player)
	player.set_physics_process(false)
	var pickup_scene: PackedScene = load("res://scene/pickup.tscn")
	var pickup = pickup_scene.instantiate()
	pickup.config = load("res://resources/config/pickup_speed.tres")
	pickup.position = Vector2(200, 200)
	world.add_child(pickup)
	pickup.set_physics_process(false)
	var sprite: Sprite2D = pickup.get_node("Sprite2D")
	if not pickup.has_method("_physics_process"):
		_check(false, "ground pickup must update lifetime and blinking")
		world.free()
		return
	pickup._physics_process(1.875)
	_check(sprite.visible and not pickup.is_queued_for_deletion(), "pickup stays visible before final second")
	pickup._physics_process(0.125)
	_check(not pickup.is_queued_for_deletion(), "pickup remains available at two seconds")
	pickup._physics_process(0.125)
	_check(not sprite.visible, "pickup blinks off during final second")
	pickup._physics_process(0.125)
	_check(sprite.visible, "pickup blinks back on rapidly")
	pickup._physics_process(0.625)
	_check(not pickup.is_queued_for_deletion(), "pickup survives until just before three seconds")
	pickup._physics_process(0.125)
	_check(pickup.is_queued_for_deletion(), "uncollected pickup expires at three seconds")
	pickup._on_body_entered(player)
	_close(player.buff_controller.get_remaining_time(0), 0.0, "expired pickup cannot grant a buff before deferred deletion")
	var blinking = pickup_scene.instantiate()
	blinking.config = load("res://resources/config/pickup_speed.tres")
	blinking.position = Vector2(220, 200)
	world.add_child(blinking)
	blinking.set_physics_process(false)
	blinking._physics_process(2.125)
	_check(not blinking.get_node("Sprite2D").visible, "collection fixture is in hidden blink phase")
	blinking._on_body_entered(player)
	_close(player.buff_controller.move_speed_multiplier, 1.5, "hidden blink phase still allows pickup")
	_check(blinking.is_queued_for_deletion(), "collected blinking pickup is removed")
	var natural = pickup_scene.instantiate()
	natural.config = load("res://resources/config/pickup_speed.tres")
	natural.position = Vector2(240, 200)
	world.add_child(natural)
	paused = true
	await create_timer(0.05, true).timeout
	_check(is_instance_valid(natural) and natural.get_node("Sprite2D").visible, "paused ground pickup remains visible and alive")
	paused = false
	await create_timer(3.15).timeout
	_check(not is_instance_valid(natural), "normal scene processing automatically removes uncollected pickup")
	world.queue_free()
	await process_frame


func _count_pickups(parent: Node) -> int:
	var count := 0
	for child in parent.get_children():
		if child is Pickup:
			count += 1
		count += _count_pickups(child)
	return count


func _count_bullets(parent: Node) -> int:
	var count := 0
	for child in parent.get_children():
		if child is Bullet:
			count += 1
	return count


func _config(type: int, duration: float, movement: float = 1.0, fire: float = 1.0) -> Resource:
	var config: Resource = CONFIG.new()
	config.set("pickup_type", type)
	config.set("duration", duration)
	config.set("move_speed_multiplier", movement)
	config.set("fire_rate_multiplier", fire)
	if type == 2:
		config.set("player_form_mode", 1)
		config.set("shot_pattern", 1)
	return config


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr("FAIL: ", description)


func _close(actual: float, expected: float, description: String) -> void:
	_check(is_equal_approx(actual, expected), "%s (expected %s, got %s)" % [description, expected, actual])


func _finish() -> void:
	print("Buff system: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
