extends SceneTree

var checks: int = 0
var failures: int = 0
var world: Node2D


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var available := true
	for path in ["res://scene/enemy.tscn", "res://scene/enemy_director.gd", "res://scene/explosion.tscn"]:
		_check(FileAccess.file_exists(path), "required enemy system resource: " + path)
		available = available and FileAccess.file_exists(path)
	await _test_player_health()
	if FileAccess.file_exists("res://scene/enemy.tscn"):
		await _test_enemy_variants()
	if available:
		await _test_projectiles()
		await _test_explosions()
		await _test_map_enclosure()
		await _test_navigation_and_spawning()
		await _test_default_spawn_limit()
		await _test_same_tick_spawns()
		await _test_death_outcomes()
		await _test_contact_damage()
		await _test_survival_victory()
		await _test_game_restart()
	_finish()


func _test_player_health() -> void:
	_new_world()
	var player = load("res://scene/player.tscn").instantiate()
	world.add_child(player)
	player.set_physics_process(false)
	_check(player.has_method("take_damage"), "player accepts combat damage")
	if not player.has_method("take_damage"):
		await _clear_world()
		return
	var notifications: Array[int] = [0, 0]
	player.health_changed.connect(func(_hp: int, _max_hp: int): notifications[0] += 1)
	player.died.connect(func(): notifications[1] += 1)
	_check(player.current_hp == 3, "player begins with three health")
	_check(not player.take_damage(0), "zero damage is rejected")
	_check(player.take_damage(1), "first damage is accepted")
	_check(player.current_hp == 2, "contact removes one health")
	_check(not player.take_damage(1), "simultaneous damage respects invulnerability")
	player._physics_process(0.5)
	_check(not player.take_damage(1), "invulnerability lasts a full second")
	player._physics_process(0.5)
	_check(player.take_damage(1), "damage is accepted after one second")
	player._physics_process(1.0)
	_check(player.take_damage(1) and player.is_dead, "third hit kills player")
	_check(not player.take_damage(1), "dead player rejects further damage")
	_check(not player.apply_pickup(load("res://resources/config/pickup_speed.tres")), "dead player cannot collect buffs")
	_check(not player._fire_bullets(Vector2.RIGHT), "dead player cannot fire")
	_check(notifications == [3, 1], "health changes and death notify exactly once")
	await _clear_world()


func _test_enemy_variants() -> void:
	_new_world()
	var names := ["normal", "armored", "fast", "explosive"]
	var health := [4, 8, 2, 4]
	var speeds := [40.0, 30.0, 60.0, 40.0]
	var rows := [1, 3, 2, 0]
	var drops := [0.2, 0.2, 0.2, 0.8]
	var weights := [Vector3(0.5, 0.5, 0), Vector3(0.4, 0.4, 0.2), Vector3(0.4, 0.4, 0.2), Vector3(0.2, 0.2, 0.6)]
	for index in names.size():
		var config = load("res://resources/config/enemy_%s.tres" % names[index])
		_check(config != null, "variant config exists: " + names[index])
		if config == null:
			continue
		_check(config.max_hp == health[index] and is_equal_approx(config.move_speed, speeds[index]), "variant health and speed: " + names[index])
		_check(is_equal_approx(config.drop_chance, drops[index]) and config.drop_weights.is_equal_approx(weights[index]), "variant drop rate and conditional weights: " + names[index])
		_check(config.choose_pickup(0.0).pickup_type == 0, "drop range starts with speed")
		_check(config.choose_pickup(weights[index].x).pickup_type == 1, "drop boundary advances to rapid")
		_check(config.choose_pickup(0.99999).pickup_type == (1 if index == 0 else 2), "drop range ends with allowed pickup")
		var enemy = _enemy(config, Vector2(100, 100))
		var sprite: AnimatedSprite2D = enemy.get_node("BodySprite")
		var frame: AtlasTexture = sprite.sprite_frames.get_frame_texture(&"move", 0)
		_check(frame.region == Rect2(0, rows[index] * 32, 32, 32), "variant selects correct sprite row: " + names[index])
		_check(sprite.sprite_frames.get_frame_count(&"death") == 6, "six death frames")
		_check(is_equal_approx(enemy.get_node("CollisionShape2D").shape.radius, 4.0 if index == 2 else 6.0), "variant collision radius")
		var deaths: Array[int] = [0]
		enemy.died.connect(func(_enemy: Node2D): deaths[0] += 1)
		_check(not enemy.take_damage(-1), "negative enemy damage is rejected")
		for hit in health[index] - 1:
			_check(enemy.take_damage(1) and not enemy.is_dead, "enemy survives nonlethal bullet")
		_check(enemy.take_damage(1) and enemy.is_dead, "exact bullet count kills variant")
		_check(not enemy.take_damage(1) and deaths[0] == 1, "enemy death cannot repeat")
		_check(sprite.animation == &"death" and enemy.velocity == Vector2.ZERO, "death starts effect and stops movement")
	await create_timer(0.8).timeout
	_check(world.get_child_count() == 0, "completed death animations clean up enemies")
	await _clear_world()


func _enemy(config: Resource, at: Vector2):
	var enemy = load("res://scene/enemy.tscn").instantiate()
	enemy.config = config
	enemy.position = at
	world.add_child(enemy)
	enemy.set_physics_process(false)
	return enemy


func _test_projectiles() -> void:
	_new_world()
	var config = load("res://resources/config/enemy_normal.tres")
	var first = _enemy(config, Vector2(50, 50))
	var second = _enemy(config, Vector2(80, 50))
	_wall(Vector2(110, 50), Vector2(2, 60))
	await _frames(3)
	var bullet = _bullet(Vector2(10, 50))
	bullet._physics_process(0.5)
	_check(first.current_hp == 3 and second.current_hp == 4, "fast bullet hits only nearest enemy before wall")
	bullet._physics_process(0.5)
	_check(first.current_hp == 3, "consumed bullet cannot damage twice")
	await process_frame
	_check(not is_instance_valid(bullet), "enemy hit consumes bullet")
	var hidden = _enemy(config, Vector2(140, 50))
	await _frames(2)
	var wall_bullet = _bullet(Vector2(95, 50))
	wall_bullet._physics_process(0.5)
	_check(hidden.current_hp == 4 and wall_bullet.is_queued_for_deletion(), "wall blocks enemy hit behind it")
	var overlap = _bullet(second.global_position)
	overlap._physics_process(0.0)
	_check(second.current_hp == 3 and overlap.is_queued_for_deletion(), "bullet born overlapping enemy hits once")
	var graze = _bullet(Vector2(10, 58))
	graze._physics_process(0.2)
	_check(first.current_hp == 2, "swept bullet radius catches a grazing hit")
	await _clear_world()


func _test_explosions() -> void:
	_new_world()
	var normal = load("res://resources/config/enemy_normal.tres")
	var near = _enemy(normal, Vector2(80, 100))
	var edge = _enemy(normal, Vector2(100, 132))
	var outside = _enemy(normal, Vector2(100, 133))
	var blocked = _enemy(normal, Vector2(124, 100))
	_wall(Vector2(112, 100), Vector2(2, 20))
	var player = load("res://scene/player.tscn").instantiate()
	player.position = Vector2(90, 90)
	world.add_child(player)
	player.set_physics_process(false)
	await _frames(3)
	var explosion = load("res://scene/explosion.tscn").instantiate()
	explosion.position = Vector2(100, 100)
	world.add_child(explosion)
	explosion.detonate()
	explosion.detonate()
	_check(near.is_dead and edge.is_dead, "explosion kills normal enemies through inclusive radius 32")
	_check(outside.current_hp == 4, "explosion respects center-distance boundary")
	_check(blocked.current_hp == 4, "World wall blocks explosion")
	_check(player.current_hp == 2, "explosion deals one player damage once")
	_check(not player.take_damage(1), "explosion and contact share player invulnerability")
	await create_timer(0.8).timeout
	_check(not is_instance_valid(explosion), "explosion animation cleans itself up")
	await _clear_world()


func _test_map_enclosure() -> void:
	var game = load("res://scene/game.tscn").instantiate()
	root.add_child(game)
	world = game
	current_scene = game
	var director = game.get_node("EnemyDirector")
	director.set_physics_process(false)
	var player = game.get_node("Player")
	player.set_physics_process(false)
	await _frames(4)
	var ground: TileMapLayer = game.get_node("GroundTileMapLayer")
	var doors: TileMapLayer = game.get_node("OverlayTileMapLayer")
	_check(ground.position == Vector2.ZERO and ground.get_used_rect() == Rect2i(0, 0, 16, 16), "map uses aligned 16 by 16 grid")
	_check(doors.get_used_cells().size() == 2, "map contains exactly two decorative red doors")
	for cell in [Vector2i(0, 7), Vector2i(15, 7)]:
		var tile: TileData = doors.get_cell_tile_data(cell)
		var center := doors.map_to_local(cell) - Vector2(tile.texture_origin)
		_check(is_equal_approx(center.y, 128.0), "tall door artwork is centered on the boundary midpoint")
	var space: PhysicsDirectSpaceState2D = game.get_world_2d().direct_space_state
	for y in 16:
		for x in 16:
			if x != 0 and x != 15 and y != 0 and y != 15:
				continue
			var query := PhysicsPointQueryParameters2D.new()
			query.position = Vector2(x * 16 + 8, y * 16 + 8)
			query.collision_mask = 1
			_check(not space.intersect_point(query).is_empty(), "outer wall has World collision at cell %s" % Vector2i(x, y))
	for point in [Vector2(24, 120), Vector2(40, 120), Vector2(24, 136), Vector2(40, 136), Vector2(232, 120), Vector2(216, 120), Vector2(232, 136), Vector2(216, 136)]:
		_check(director.is_position_clear(point) and director.has_route(point, player.position), "red-gate inward corridor is clear and reachable at %s" % point)
	var enemy = _enemy(load("res://resources/config/enemy_normal.tres"), Vector2(64, 64))
	for sample in [
		[Vector2(32, 128), Vector2.LEFT], [Vector2(224, 128), Vector2.RIGHT],
		[Vector2(128, 32), Vector2.UP], [Vector2(128, 224), Vector2.DOWN],
		[Vector2(32, 32), Vector2(-1, -1)], [Vector2(224, 32), Vector2(1, -1)],
		[Vector2(32, 224), Vector2(-1, 1)], [Vector2(224, 224), Vector2(1, 1)],
	]:
		var start: Vector2 = sample[0]
		var direction: Vector2 = sample[1]
		player.position = start
		player.move_and_collide(direction * 64)
		_check(player.position.x >= 21.9 and player.position.x <= 234.1 and player.position.y >= 21.9 and player.position.y <= 234.1, "player cannot cross wall, gate or corner from %s" % start)
		enemy.position = start
		enemy.move_and_collide(direction * 64)
		_check(enemy.position.x >= 21.9 and enemy.position.x <= 234.1 and enemy.position.y >= 21.9 and enemy.position.y <= 234.1, "enemy cannot cross wall, gate or corner from %s" % start)
		var bullet = _bullet(start)
		bullet.setup(direction)
		bullet._physics_process(0.3)
		_check(bullet.is_queued_for_deletion(), "bullet stops at wall, gate or corner from %s" % start)
	await _clear_world()


func _test_navigation_and_spawning() -> void:
	var game = load("res://scene/game.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	world = game
	_check(game.has_node("EnemyDirector"), "main scene contains enemy director")
	if not game.has_node("EnemyDirector"):
		await _clear_world()
		return
	var director = game.get_node("EnemyDirector")
	director.set_physics_process(false)
	var player = game.get_node("Player")
	player.set_physics_process(false)
	await _frames(4)
	_check(director.navigation_ready, "navigation initializes after physics synchronization")
	_check(director.spawn_points.get_child_count() == 2, "main map has two red-gate spawns")
	var gate: Marker2D = director.spawn_points.get_node("LeftGate")
	var second_gate: Marker2D = director.spawn_points.get_node_or_null("RightGate")
	_check(gate.position == Vector2(8, 128), "left gate is at boundary midpoint")
	_check(second_gate != null and second_gate.position == Vector2(248, 128), "right gate is at boundary midpoint")
	# 单门测试夹具暂时移出右门，验证独立频率后再恢复双门。
	if second_gate == null:
		second_gate = Marker2D.new()
		second_gate.name = "RightGate"
		second_gate.position = Vector2(248, 128)
		second_gate.rotation = PI
	else:
		director.spawn_points.remove_child(second_gate)
	_check(director.alive_limit == 15, "default shared alive limit is fifteen")
	var configs: Array = director.enemy_configs
	for sample in [[0.0, 0], [0.59999, 0], [0.6, 1], [0.74999, 1], [0.75, 2], [0.89999, 2], [0.9, 3], [0.99999, 3]]:
		_check(director.choose_enemy(sample[0]) == configs[sample[1]], "spawn probability boundary %s" % sample[0])
	director.advance_spawning(1.99)
	_check(director.get_alive_count() == 0, "initial two-second delay prevents early spawn")
	director.advance_spawning(0.01)
	_check(director.get_alive_count() == 1, "one red gate spawns one enemy after initial delay")
	var spawned: Array = get_nodes_in_group(&"enemies")
	for enemy in spawned:
		enemy.set_physics_process(false)
		_check(enemy.global_position.distance_to(player.global_position) >= 64.0, "gate spawn respects player safety distance")
		_check(enemy.global_position.x > gate.global_position.x and enemy.global_position.x <= gate.global_position.x + 32.0, "enemy spawns inward within own gate region")
		enemy.position = Vector2(150, 150)
	director.spawn_points.add_child(second_gate)
	director.advance_spawning(1.49)
	_check(director.get_alive_count() == 1, "per-gate interval is a full 1.5 seconds")
	director.advance_spawning(0.01)
	_check(director.get_alive_count() == 3, "two gates each spawn one enemy in a tick")
	for enemy in get_nodes_in_group(&"enemies"):
		enemy.set_physics_process(false)
		enemy.position = Vector2(150, 150)
	await _frames(2)
	director.alive_limit = 4
	director.advance_spawning(1.5)
	_check(director.get_alive_count() == 4, "shared cap applies across gates")
	var cap_spawn: Node2D = get_nodes_in_group(&"enemies").back()
	_check(cap_spawn.global_position.x >= 216.0, "rotating gate order gives right gate the next available slot")
	cap_spawn.free()
	await _frames(2)
	director.advance_spawning(1.5)
	cap_spawn = get_nodes_in_group(&"enemies").back()
	_check(cap_spawn.global_position.x <= 40.0, "next free slot rotates back to left gate")
	director.advance_spawning(20.0)
	_check(director.get_alive_count() == 4, "blocked intervals do not accumulate a burst")
	for enemy in get_nodes_in_group(&"enemies"):
		enemy.free()
	await _frames(2)
	second_gate.queue_free()
	await process_frame
	player.position = Vector2(30, 128)
	director.advance_spawning(1.5)
	_check(director.get_alive_count() == 0, "player camping a gate suppresses unsafe spawning")
	player.position = Vector2(180, 180)
	_wall(Vector2(24, 128), Vector2(64, 48))
	await _frames(3)
	director.advance_spawning(1.5)
	_check(director.get_alive_count() == 0, "live World obstruction blocks gate spawn")
	await _clear_world()
	await _test_path_progress(Vector2.ZERO)
	await _test_path_progress(Vector2(37, 19))


func _test_path_progress(shift: Vector2) -> void:
	var game = load("res://scene/game.tscn").instantiate()
	game.position = shift
	root.add_child(game)
	world = game
	current_scene = game
	var director = game.get_node("EnemyDirector")
	director.set_physics_process(false)
	var player = game.get_node("Player")
	player.set_physics_process(false)
	player.position = Vector2(184, 104)
	_wall(shift + Vector2(128, 104), Vector2(16, 112))
	await _frames(3)
	director.rebuild_navigation()
	var enemy = director.spawn_enemy(load("res://resources/config/enemy_normal.tres"), shift + Vector2(72, 104))
	var start_distance: float = enemy.global_position.distance_to(player.global_position)
	for frame in 330:
		await physics_frame
	_check(enemy.global_position.distance_to(player.global_position) < 20.0, "enemy repeatedly repaths around wall and reaches player with map shift %s (start %s, end %s)" % [shift, start_distance, enemy.global_position])
	_check(not enemy.test_move(enemy.global_transform, Vector2.ZERO), "enemy never embeds in World geometry")
	await _clear_world()


func _test_default_spawn_limit() -> void:
	var game = load("res://scene/game.tscn").instantiate()
	root.add_child(game)
	world = game
	current_scene = game
	var director = game.get_node("EnemyDirector")
	director.set_physics_process(false)
	game.get_node("Player").set_physics_process(false)
	await _frames(4)
	var config = load("res://resources/config/enemy_normal.tres").duplicate()
	config.drop_chance = 0.0
	for index in 14:
		var enemy = director.spawn_enemy(config, Vector2(150, 150))
		enemy.set_physics_process(false)
	director.advance_spawning(2.0)
	_check(director.get_alive_count() == 15, "two gates share the last slot when fourteen enemies are alive")
	for enemy in get_nodes_in_group(&"enemies"):
		enemy.set_physics_process(false)
		enemy.position = Vector2(150, 150)
	await _frames(2)
	director.advance_spawning(1.5)
	_check(director.get_alive_count() == 15, "default shared cap prevents a sixteenth living enemy")
	var victim = get_nodes_in_group(&"enemies")[0]
	_check(victim.take_damage(victim.current_hp) and director.get_alive_count() == 14, "enemy death immediately releases one shared slot")
	director.advance_spawning(1.49)
	_check(director.get_alive_count() == 14, "released slot waits for the next complete 1.5-second interval")
	director.advance_spawning(0.01)
	_check(director.get_alive_count() == 15, "next interval refills only the released slot")
	await _clear_world()


func _test_same_tick_spawns() -> void:
	var game = load("res://scene/game.tscn").instantiate()
	root.add_child(game)
	world = game
	current_scene = game
	var director = game.get_node("EnemyDirector")
	director.set_physics_process(false)
	game.get_node("Player").position = Vector2(180, 180)
	game.get_node("Player").set_physics_process(false)
	await _frames(4)
	# 重叠入口竞争有限的合法格，新物理体尚未同步也不能重叠。
	for index in 2:
		var gate: Marker2D = director.spawn_points.get_child(0).duplicate()
		director.spawn_points.add_child(gate)
	director.rng.seed = 7
	director.spawn_cycle()
	var enemies := get_nodes_in_group(&"enemies")
	var separated := true
	for first in enemies.size():
		for second in range(first + 1, enemies.size()):
			var required: float = enemies[first].config.collision_radius + enemies[second].config.collision_radius
			separated = separated and enemies[first].global_position.distance_to(enemies[second].global_position) >= required
	_check(separated, "same-tick gate spawns never overlap unregistered enemy bodies")
	await _clear_world()


func _test_death_outcomes() -> void:
	var game = load("res://scene/game.tscn").instantiate()
	root.add_child(game)
	world = game
	current_scene = game
	var director = game.get_node("EnemyDirector")
	director.set_physics_process(false)
	game.get_node("Player").position = Vector2(200, 200)
	game.get_node("Player").set_physics_process(false)
	await _frames(4)
	var guaranteed = load("res://resources/config/enemy_normal.tres").duplicate()
	guaranteed.drop_chance = 1.0
	var victim = director.spawn_enemy(guaranteed, Vector2(80, 80))
	victim.take_damage(100)
	victim.take_damage(100)
	_check(director.get_alive_count() == 0, "death immediately releases living capacity")
	await process_frame
	_check(_count_type(world, "Pickup") == 1, "one death drops at most one pickup")
	var explosive = load("res://resources/config/enemy_explosive.tres").duplicate()
	explosive.drop_chance = 0.0
	var a = director.spawn_enemy(explosive, Vector2(80, 100))
	var b = director.spawn_enemy(explosive, Vector2(104, 100))
	var c = director.spawn_enemy(explosive, Vector2(128, 100))
	for enemy in [a, b, c]:
		enemy.set_physics_process(false)
	a.take_damage(4)
	a.position = Vector2(230, 230)
	await process_frame
	_check(a.is_dead and b.is_dead and c.is_dead, "saved death origin allows one-shot explosion chain")
	_check(_count_type(world, "Explosion") == 3, "chain creates exactly one effect per explosive enemy")
	await _clear_world()


func _test_contact_damage() -> void:
	for variant in ["normal", "armored", "fast", "explosive"]:
		_new_world()
		var player = load("res://scene/player.tscn").instantiate()
		player.position = Vector2(100, 100)
		world.add_child(player)
		var enemy = _enemy(load("res://resources/config/enemy_%s.tres" % variant), player.position)
		enemy.target = player
		enemy.set_physics_process(true)
		await _frames(5)
		_check(player.current_hp == 2, "%s real overlap deals exactly one initial damage" % variant)
		await create_timer(1.1).timeout
		_check(player.current_hp == 1, "%s continuous overlap damages again after invulnerability" % variant)
		await _clear_world()


func _test_survival_victory() -> void:
	var game = load("res://scene/game.tscn").instantiate()
	root.add_child(game)
	world = game
	current_scene = game
	game.set_physics_process(false)
	var player = game.get_node("Player")
	player.set_physics_process(false)
	var director = game.get_node("EnemyDirector")
	director.set_physics_process(false)
	var countdown: TextureProgressBar = game.get_node_or_null("HUD/Countdown")
	_check(countdown != null, "survival countdown is visible in the HUD")
	_check(game.has_method("_physics_process"), "game advances the survival countdown")
	if countdown == null or not game.has_method("_physics_process"):
		await _clear_world()
		return
	await _frames(4)
	_check(countdown.visible and is_equal_approx(countdown.value, 60.0) and is_equal_approx(countdown.ratio, 1.0), "round begins with a full sixty-second bar")
	var texture := countdown.texture_progress as AtlasTexture
	_check(texture != null and texture.atlas == load("res://resources/texture/道具ui.png") and texture.region == Rect2(16, 6, 48, 7), "countdown uses the top green bar from the item UI atlas")
	game._physics_process(30.0)
	_check(is_equal_approx(countdown.value, 30.0) and is_equal_approx(countdown.ratio, 0.5), "thirty elapsed seconds leave half of the green bar")
	paused = true
	game._physics_process(10.0)
	_check(is_equal_approx(countdown.value, 30.0), "paused gameplay does not consume survival time")
	paused = false
	game._physics_process(29.75)
	_check(not paused and not game.get_node("HUD/GameOver").visible and is_equal_approx(countdown.value, 0.25), "survival cannot win before the full minute")
	player.take_damage(2)
	player.apply_pickup(load("res://resources/config/pickup_speed.tres"))
	var enemy = director.spawn_enemy(load("res://resources/config/enemy_normal.tres"), Vector2(150, 150))
	player._fire_bullets(Vector2.RIGHT)
	game._physics_process(0.25)
	var title: Label = game.get_node("HUD/GameOver/Center/Panel/Content/Title")
	_check(player.current_hp == 1 and not player.is_dead and paused, "surviving sixty seconds with one health ends the round")
	_check(countdown.value == 0.0 and game.get_node("HUD/GameOver").visible and title.text.contains("胜利"), "timeout empties the bar and displays victory")
	var before_position: Vector2 = enemy.position
	var before_buff: float = player.buff_controller.get_remaining_time(0)
	var before_count: int = director.get_alive_count()
	player.set_physics_process(true)
	director.set_physics_process(true)
	game.set_physics_process(true)
	await create_timer(0.1).timeout
	_check(enemy.position == before_position and director.get_alive_count() == before_count and player.buff_controller.get_remaining_time(0) == before_buff, "victory freezes combat, spawning and buff time")
	game._physics_process(5.0)
	game._on_player_died()
	_check(countdown.value == 0.0 and title.text.contains("胜利"), "finished victory cannot count down again or change to defeat")
	game.get_node("HUD/GameOver/Center/Panel/Content/Restart").pressed.emit()
	await process_frame
	await process_frame
	world = current_scene
	countdown = world.get_node("HUD/Countdown")
	_check(not paused and world != game and not world.get_node("HUD/GameOver").visible, "restart after victory begins a new active round")
	_check(countdown.value > 59.0 and countdown.value <= 60.0 and world.get_node("Player").current_hp == 3, "restart restores full survival time and health")
	_check(get_nodes_in_group(&"enemies").is_empty() and _count_type(world, "Bullet") == 0, "victory restart clears the finished round's enemies and bullets")
	var before_time: float = countdown.value
	await _frames(4)
	_check(countdown.value < before_time, "new round countdown advances automatically during gameplay")
	await _clear_world()


func _test_game_restart() -> void:
	var game = load("res://scene/game.tscn").instantiate()
	root.add_child(game)
	world = game
	current_scene = game
	_check(game.has_method("restart_game"), "main scene supports game-over restart")
	if not game.has_method("restart_game"):
		await _clear_world()
		return
	var director = game.get_node("EnemyDirector")
	director.set_physics_process(false)
	var player = game.get_node("Player")
	player.set_physics_process(false)
	game.set_physics_process(false)
	await _frames(4)
	if game.has_method("_physics_process"):
		game._physics_process(59.75)
	player.apply_pickup(load("res://resources/config/pickup_speed.tres"))
	director.spawn_enemy(load("res://resources/config/enemy_normal.tres"), Vector2(150, 150))
	player._fire_bullets(Vector2.RIGHT)
	player.take_damage(1)
	var count: Label = game.get_node_or_null("HUD/Health/Count")
	var avatar: TextureRect = game.get_node_or_null("HUD/Health/Avatar")
	_check(count != null and count.text == "× 2", "avatar counter reflects player health signal")
	_check(avatar != null and avatar.texture == load("res://resources/texture/icon.png") and avatar.size == Vector2(32, 32), "life HUD uses a 32 by 32 character avatar")
	_check(avatar != null and avatar.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST, "life avatar keeps pixel-art filtering")
	player._physics_process(1.0)
	player.take_damage(1)
	player._physics_process(1.0)
	player.take_damage(1)
	_check(paused and game.get_node("HUD/GameOver").visible, "player death pauses world and shows game over")
	if game.has_method("_physics_process"):
		game._physics_process(1.0)
		_check(game.get_node("HUD/GameOver/Center/Panel/Content/Title").text == "游戏结束", "death immediately before the deadline cannot become victory")
		_check(is_equal_approx(game.get_node("HUD/Countdown").value, 0.25), "defeat stops the remaining countdown")
	_check(count != null and count.text == "× 0", "dead player's avatar counter shows zero")
	_check(game.get_node("HUD").process_mode == Node.PROCESS_MODE_ALWAYS, "game-over interface remains active while paused")
	var before: int = director.get_alive_count()
	director.advance_spawning(10.0)
	_check(director.get_alive_count() == before, "dead player stops red-gate spawning")
	game.get_node("HUD/GameOver/Center/Panel/Content/Restart").pressed.emit()
	await process_frame
	await process_frame
	world = current_scene
	_check(not paused and world != game, "restart button unpauses and replaces entire scene")
	player = world.get_node("Player")
	_check(player.current_hp == 3 and not player.is_dead and player.invulnerability_remaining == 0.0, "restart resets all player damage state")
	count = world.get_node_or_null("HUD/Health/Count")
	_check(count != null and count.text == "× 3", "restart restores avatar counter to three")
	_check(player.buff_controller.move_speed_multiplier == 1.0, "restart clears old buffs")
	_check(get_nodes_in_group(&"enemies").is_empty() and _count_type(world, "Bullet") == 0 and _count_type(world, "Pickup") == 0 and _count_type(world, "Explosion") == 0, "restart clears enemies, bullets, drops and effects")
	await _frames(4)
	director = world.get_node("EnemyDirector")
	director.set_physics_process(false)
	director.advance_spawning(1.8)
	_check(director.get_alive_count() == 0, "restart restores initial spawn delay")
	await _clear_world()


func _wall(at: Vector2, size: Vector2) -> StaticBody2D:
	var wall := StaticBody2D.new()
	wall.position = at - world.global_position
	var collision := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = size
	collision.shape = shape
	wall.add_child(collision)
	world.add_child(wall)
	return wall


func _bullet(at: Vector2):
	var bullet = load("res://scene/bullet.tscn").instantiate()
	bullet.position = at
	world.add_child(bullet)
	bullet.setup(Vector2.RIGHT)
	bullet.set_physics_process(false)
	return bullet


func _frames(count: int) -> void:
	for index in count:
		await physics_frame
	await process_frame


func _count_type(parent: Node, type_name: String) -> int:
	var count := 0
	for child in parent.get_children():
		if child.get_script() != null and child.get_script().get_global_name() == type_name:
			count += 1
		count += _count_type(child, type_name)
	return count


func _new_world() -> void:
	world = Node2D.new()
	root.add_child(world)
	current_scene = world


func _clear_world() -> void:
	paused = false
	world.queue_free()
	await process_frame
	current_scene = null


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr("FAIL: ", description)


func _finish() -> void:
	print("Enemy system: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
