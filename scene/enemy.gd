extends CharacterBody2D
class_name Enemy

signal died(enemy: Enemy)

@export var config: EnemyConfig = preload("res://resources/config/enemy_normal.tres")

@onready var _audio: Node = get_node("/root/AudioManager")
@onready var body_sprite: AnimatedSprite2D = $BodySprite
@onready var contact_sensor: Area2D = $ContactSensor

var current_hp: int
var is_dead: bool = false
var target: Player
var director: Node
var waypoints: PackedVector2Array = []
var repath_remaining: float = 0.0


func _ready() -> void:
	current_hp = config.max_hp
	var body_shape := CircleShape2D.new()
	body_shape.radius = config.collision_radius
	$CollisionShape2D.shape = body_shape
	$ContactSensor/CollisionShape2D.shape = body_shape
	body_sprite.sprite_frames = config.get_sprite_frames()
	body_sprite.play(&"move")
	body_sprite.animation_finished.connect(_on_animation_finished)
	add_to_group(&"enemies")


func _physics_process(delta: float) -> void:
	if is_dead:
		return
	var direction := Vector2.ZERO
	if is_instance_valid(target) and not target.is_dead:
		if is_instance_valid(director):
			direction = director.get_movement_direction(self, delta)
		else:
			direction = global_position.direction_to(target.global_position)
	velocity = direction * config.move_speed
	move_and_slide()
	if velocity.length_squared() > 0.01:
		if absf(velocity.x) > 0.01:
			body_sprite.flip_h = velocity.x < 0.0
		body_sprite.play(&"move")
	else:
		body_sprite.pause()
	for body in contact_sensor.get_overlapping_bodies():
		if body is Player:
			body.take_damage(1)


func take_damage(amount: int) -> bool:
	if is_dead or amount <= 0:
		return false
	current_hp = maxi(current_hp - amount, 0)
	if current_hp == 0:
		is_dead = true
		velocity = Vector2.ZERO
		collision_layer = 0
		$CollisionShape2D.set_deferred("disabled", true)
		contact_sensor.set_deferred("monitoring", false)
		body_sprite.play(&"death")
		_audio.play_sfx(&"enemy_death")
		died.emit(self)
	return true


func _on_animation_finished() -> void:
	if is_dead:
		queue_free()
