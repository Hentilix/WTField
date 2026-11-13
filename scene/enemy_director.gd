extends Node2D
class_name EnemyDirector

const ENEMY_SCENE := preload("res://scene/enemy.tscn")
const PICKUP_SCENE := preload("res://scene/pickup.tscn")
const EXPLOSION_SCENE := preload("res://scene/explosion.tscn")
const NAVIGATION_RADIUS := 6.0

@export var enemy_configs: Array[EnemyConfig] = [
	preload("res://resources/config/enemy_normal.tres"),
	preload("res://resources/config/enemy_armored.tres"),
	preload("res://resources/config/enemy_fast.tres"),
	preload("res://resources/config/enemy_explosive.tres"),
]
@export var initial_delay: float = 2.0
@export var spawn_interval: float = 1.5
@export var alive_limit: int = 15
@export var minimum_player_distance: float = 64.0
@export var gate_depth: float = 32.0

@onready var player: Player = get_parent().get_node("Player")
@onready var ground: TileMapLayer = get_parent().get_node("GroundTileMapLayer")
@onready var spawn_points: Node2D = $SpawnPoints

var navigation := AStarGrid2D.new()
var navigation_ready: bool = false
var rng := RandomNumberGenerator.new()
var _remaining: float
var _next_gate: int = 0
var _living: Array[Enemy] = []
var _pending_deaths: Array[Dictionary] = []
var _resolving_deaths: bool = false


func _ready() -> void:
	rng.randomize()
	_remaining = initial_delay
	_initialize_navigation.call_deferred()


func _initialize_navigation() -> void:
	# 等待瓦片与边界注册到物理空间，再建立静态导航图。
	await get_tree().physics_frame
	await get_tree().physics_frame
	rebuild_navigation()


func rebuild_navigation() -> void:
	navigation.region = ground.get_used_rect()
	navigation.cell_size = Vector2(ground.tile_set.tile_size)
	navigation.offset = ground.to_global(ground.map_to_local(Vector2i.ZERO))
	navigation.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	navigation.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	navigation.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	navigation.update()
	for y in range(navigation.region.position.y, navigation.region.end.y):
		for x in range(navigation.region.position.x, navigation.region.end.x):
			var cell := Vector2i(x, y)
			var blocked := ground.get_cell_source_id(cell) == -1 or not is_position_clear(navigation.get_point_position(cell))
			navigation.set_point_solid(cell, blocked)
	navigation_ready = true


func _physics_process(delta: float) -> void:
	advance_spawning(delta)


func advance_spawning(delta: float) -> void:
	if not navigation_ready or player.is_dead:
		return
	_remaining -= delta
	if _remaining > 0.000001:
		return
	_remaining = spawn_interval
	spawn_cycle()


func spawn_cycle() -> void:
	if player.is_dead or not navigation_ready:
		return
	var gates := spawn_points.get_children()
	if gates.is_empty():
		return
	for index in gates.size():
		if get_alive_count() >= alive_limit:
			break
		var gate: Node2D = gates[(_next_gate + index) % gates.size()]
		var candidates := _gate_candidates(gate)
		if not candidates.is_empty():
			var at := candidates[rng.randi_range(0, candidates.size() - 1)]
			spawn_enemy(choose_enemy(rng.randf()), at)
	_next_gate = (_next_gate + 1) % gates.size()


func choose_enemy(roll: float) -> EnemyConfig:
	var total := 0.0
	for config in enemy_configs:
		total += config.spawn_weight
	var point := clampf(roll, 0.0, 0.999999) * total
	for config in enemy_configs:
		point -= config.spawn_weight
		if point < -0.0000001:
			return config
	return enemy_configs.back()


func spawn_enemy(config: EnemyConfig, at: Vector2) -> Enemy:
	var enemy := ENEMY_SCENE.instantiate() as Enemy
	enemy.config = config
	enemy.target = player
	enemy.director = self
	enemy.position = get_parent().to_local(at)
	enemy.died.connect(_on_enemy_died)
	enemy.tree_exiting.connect(func(): _living.erase(enemy))
	_living.append(enemy)
	get_parent().add_child(enemy)
	return enemy


func get_alive_count() -> int:
	return _living.size()


func _gate_candidates(gate: Node2D) -> PackedVector2Array:
	var candidates := PackedVector2Array()
	var inward := gate.global_transform.x.normalized()
	for y in range(navigation.region.position.y, navigation.region.end.y):
		for x in range(navigation.region.position.x, navigation.region.end.x):
			var cell := Vector2i(x, y)
			if navigation.is_point_solid(cell):
				continue
			var point := navigation.get_point_position(cell)
			var offset := point - gate.global_position
			if offset.dot(inward) <= 0.0 or offset.dot(inward) > gate_depth or absf(offset.dot(inward.orthogonal())) > 8.0:
				continue
			if point.distance_squared_to(player.global_position) < minimum_player_distance * minimum_player_distance:
				continue
			# 新出生的物理体要到下一物理帧才可查询，同帧先保留其占用空间。
			var occupied := false
			for enemy in _living:
				var clearance := NAVIGATION_RADIUS + enemy.config.collision_radius
				if point.distance_squared_to(enemy.global_position) < clearance * clearance:
					occupied = true
					break
			if occupied:
				continue
			if not is_position_clear(point, 1 | 4) or not has_route(point, player.global_position):
				continue
			candidates.append(point)
	return candidates


func is_position_clear(at: Vector2, mask: int = 1) -> bool:
	var query := _circle_query(at, NAVIGATION_RADIUS)
	query.collision_mask = mask
	return get_world_2d().direct_space_state.intersect_shape(query).is_empty()


func _circle_query(at: Vector2, radius: float) -> PhysicsShapeQueryParameters2D:
	var shape := CircleShape2D.new()
	shape.radius = radius
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = shape
	query.transform = Transform2D(0.0, at)
	query.collision_mask = 1
	query.collide_with_areas = false
	return query


func _segment_clear(from: Vector2, to: Vector2, radius: float) -> bool:
	var query := _circle_query(from, radius)
	var space := get_world_2d().direct_space_state
	if not space.intersect_shape(query).is_empty():
		return false
	query.motion = to - from
	return space.cast_motion(query)[0] >= 1.0


func _nearest_cell(at: Vector2) -> Vector2i:
	var closest := Vector2i(-1, -1)
	var distance := INF
	for y in range(navigation.region.position.y, navigation.region.end.y):
		for x in range(navigation.region.position.x, navigation.region.end.x):
			var cell := Vector2i(x, y)
			if navigation.is_point_solid(cell):
				continue
			var squared := navigation.get_point_position(cell).distance_squared_to(at)
			if squared < distance:
				distance = squared
				closest = cell
	return closest


func has_route(from: Vector2, to: Vector2) -> bool:
	var start := _nearest_cell(from)
	var end := _nearest_cell(to)
	return start != Vector2i(-1, -1) and end != Vector2i(-1, -1) and not navigation.get_id_path(start, end).is_empty()


func get_movement_direction(enemy: Enemy, delta: float) -> Vector2:
	var destination := player.global_position
	if enemy.global_position.distance_squared_to(destination) < 1.0:
		return Vector2.ZERO
	if _segment_clear(enemy.global_position, destination, enemy.config.collision_radius):
		enemy.waypoints.clear()
		return enemy.global_position.direction_to(destination)
	enemy.repath_remaining -= delta
	if enemy.repath_remaining <= 0.0 and navigation_ready:
		enemy.repath_remaining = 0.25
		var start := _nearest_cell(enemy.global_position)
		var end := _nearest_cell(destination)
		if start != Vector2i(-1, -1) and end != Vector2i(-1, -1):
			enemy.waypoints = navigation.get_point_path(start, end, true)
	# 从最远的安全可见路点继续前进，重算不会拉回当前格中心。
	for index in range(enemy.waypoints.size() - 1, -1, -1):
		var waypoint := enemy.waypoints[index]
		if enemy.global_position.distance_squared_to(waypoint) < 4.0:
			enemy.waypoints.remove_at(index)
			continue
		if _segment_clear(enemy.global_position, waypoint, enemy.config.collision_radius):
			return enemy.global_position.direction_to(waypoint)
	return Vector2.ZERO


func _on_enemy_died(enemy: Enemy) -> void:
	_living.erase(enemy)
	_pending_deaths.append({"position": enemy.global_position, "config": enemy.config})
	if not _resolving_deaths:
		_resolving_deaths = true
		_resolve_deaths.call_deferred()


func _resolve_deaths() -> void:
	while not _pending_deaths.is_empty():
		var death: Dictionary = _pending_deaths.pop_front()
		var config: EnemyConfig = death["config"]
		var at: Vector2 = death["position"]
		if rng.randf() < config.drop_chance:
			var pickup := PICKUP_SCENE.instantiate() as Pickup
			pickup.config = config.choose_pickup(rng.randf())
			pickup.position = get_parent().to_local(at)
			get_parent().add_child(pickup)
		if config.explodes:
			var explosion := EXPLOSION_SCENE.instantiate() as Explosion
			explosion.position = get_parent().to_local(at)
			get_parent().add_child(explosion)
			explosion.detonate()
	_resolving_deaths = false
