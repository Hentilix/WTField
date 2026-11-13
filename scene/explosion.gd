extends Node2D
class_name Explosion

const SHEET := preload("res://resources/texture/爆炸特效.png")
const RADIUS := 32.0

var _detonated: bool = false



@onready var _audio: Node = get_node("/root/AudioManager")

func _ready() -> void:
	var frames := SpriteFrames.new()
	frames.set_animation_loop(&"default", false)
	frames.set_animation_speed(&"default", 10.0)
	for column in 5:
		var texture := AtlasTexture.new()
		texture.atlas = SHEET
		texture.region = Rect2(column * 48, 0, 48, 48)
		frames.add_frame(&"default", texture)
	$AnimatedSprite2D.sprite_frames = frames
	$AnimatedSprite2D.animation_finished.connect(queue_free)
	$AnimatedSprite2D.play(&"default")


func detonate() -> void:
	if _detonated:
		return
	_detonated = true
	_audio.play_sfx(&"explosion")
	var targets := get_tree().get_nodes_in_group(&"enemies") + get_tree().get_nodes_in_group(&"players")
	for body: Node2D in targets:
		if body.is_dead or global_position.distance_squared_to(body.global_position) > RADIUS * RADIUS:
			continue
		var query := PhysicsRayQueryParameters2D.create(global_position, body.global_position, 1)
		query.hit_from_inside = true
		if get_world_2d().direct_space_state.intersect_ray(query).is_empty():
			body.take_damage(1 if body is Player else 4)
