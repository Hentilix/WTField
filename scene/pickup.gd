extends Area2D
class_name Pickup

const LIFETIME := 3.0
const BLINK_DURATION := 1.0
const BLINK_INTERVAL := 0.1

@export var config: PickupConfig

var _collected: bool = false
var _age: float = 0.0



@onready var _audio: Node = get_node("/root/AudioManager")

func _ready() -> void:
	if config != null:
		$Sprite2D.texture = config.icon_texture
	body_entered.connect(_on_body_entered)


func _physics_process(delta: float) -> void:
	if _collected or is_queued_for_deletion():
		return
	_age += delta
	if _age >= LIFETIME:
		hide()
		queue_free()
		return
	# 只闪烁图标，保持碰撞检测，闪烁期间仍然可以拾取。
	var blink_time := _age - (LIFETIME - BLINK_DURATION)
	if blink_time >= 0.0:
		$Sprite2D.visible = int(blink_time / BLINK_INTERVAL) % 2 == 0


func _on_body_entered(body: Node2D) -> void:
	if _collected or is_queued_for_deletion() or not body is Player:
		return
	if not (body as Player).apply_pickup(config):
		return
	# queue_free 延迟到帧末，立即标记避免同一帧重复领取。
	_collected = true
	_audio.play_sfx(&"pickup")
	hide()
	queue_free()
