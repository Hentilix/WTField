extends Area2D
class_name Bullet

const HIT_MASK := 1 | 4 # World、EnemyBody。

# speed of bullet, pt/s
@export var speed: float = 320.0
# max life span of bullet
@export var max_lifetime: float = 2.0
@export var damage: int = 1

# direction of bullet
var direction: Vector2 = Vector2.RIGHT
# remaining lifetime of bullet
var remaining_lifetime: float = 0.0
var _consumed: bool = false

# Initialize projectile lifetime.
func _ready() -> void:
	remaining_lifetime = max_lifetime
	
	
# 由外部在生成子弹后调用，注入初始方向
func setup(initial_direction: Vector2) -> void:
	if initial_direction != Vector2.ZERO:
		direction = initial_direction.normalized()
	
	rotation = direction.angle()


# 扫掠整个飞行路径，先处理最近的世界或敌人碰撞，再推进位置。
func _physics_process(delta: float) -> void:
	if _consumed or is_queued_for_deletion():
		return
	var motion := direction * speed * delta
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = $CollisionShape2D.shape
	query.transform = global_transform
	query.collision_mask = HIT_MASK
	query.collide_with_areas = false
	query.margin = 0.001
	var space := get_world_2d().direct_space_state
	# cast_motion 不报告初始重叠，先处理出生或上一帧的重叠。
	var hits := space.intersect_shape(query)
	if hits.is_empty() and motion != Vector2.ZERO:
		query.motion = motion
		var fractions := space.cast_motion(query)
		if fractions[0] < 1.0:
			query.motion = Vector2.ZERO
			query.transform.origin += motion * fractions[1] + direction * 0.02
			hits = space.intersect_shape(query)
			if hits.is_empty():
				# 零厚度边界接触也必须回收。
				_consume(null)
				return
	if not hits.is_empty():
		var collider: Object = hits[0]["collider"]
		for hit: Dictionary in hits:
			# 瓦片碰撞的 collider 是 TileMapLayer，不是 CollisionObject2D。
			if not is_instance_valid(hit["collider"]) or not hit["collider"].has_method("take_damage"):
				collider = hit["collider"]
				break
		_consume(collider)
		return
	global_position += motion
	remaining_lifetime -= delta
	if remaining_lifetime <= 0.0:
		_consume(null)


func _consume(collider: Object) -> void:
	_consumed = true
	if collider != null and collider.has_method("take_damage"):
		collider.take_damage(damage)
	queue_free()
