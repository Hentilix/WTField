extends Resource
class_name EnemyConfig

const SHEET := preload("res://resources/texture/源石虫.png")
const PICKUPS: Array[PickupConfig] = [
	preload("res://resources/config/pickup_speed.tres"),
	preload("res://resources/config/pickup_rapid.tres"),
	preload("res://resources/config/pickup_spiral.tres"),
]

@export var display_name: String = "普通源石虫"
@export var max_hp: int = 4
@export var move_speed: float = 40.0
@export var spawn_weight: float = 0.6
@export var collision_radius: float = 6.0
@export var animation_row: int = 1
@export var animation_fps: float = 8.0
@export_range(0.0, 1.0) var drop_chance: float = 0.2
# 移速、射速、旋转的条件权重，不改写共享 PickupConfig。
@export var drop_weights: Vector3 = Vector3(0.5, 0.5, 0.0)
@export var explodes: bool = false

var _frames: SpriteFrames


func choose_pickup(roll: float) -> PickupConfig:
	var total := drop_weights.x + drop_weights.y + drop_weights.z
	var point := clampf(roll, 0.0, 0.999999) * total
	if point < drop_weights.x:
		return PICKUPS[0]
	if point < drop_weights.x + drop_weights.y:
		return PICKUPS[1]
	return PICKUPS[2]


func get_sprite_frames() -> SpriteFrames:
	if _frames != null:
		return _frames
	_frames = SpriteFrames.new()
	_frames.remove_animation(&"default")
	_frames.add_animation(&"move")
	_frames.set_animation_speed(&"move", animation_fps)
	for column in 3:
		_frames.add_frame(&"move", _frame(column, animation_row))
	_frames.add_animation(&"death")
	_frames.set_animation_loop(&"death", false)
	_frames.set_animation_speed(&"death", 10.0)
	for row in range(4, 6):
		for column in 3:
			_frames.add_frame(&"death", _frame(column, row))
	return _frames


func _frame(column: int, row: int) -> AtlasTexture:
	var texture := AtlasTexture.new()
	texture.atlas = SHEET
	texture.region = Rect2(column * 32, row * 32, 32, 32)
	return texture
