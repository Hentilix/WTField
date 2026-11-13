extends CharacterBody2D
class_name Player

signal health_changed(current_hp: int, max_hp: int)
signal died

@export var max_hp: int = 3
@export var invulnerability_duration: float = 1.0

var current_hp: int = 3
var is_dead: bool = false
var invulnerability_remaining: float = 0.0

const NORMAL_ANIMATION_PREFIX := &"normal"

const BULLET_SCENE := preload("res://scene/bullet.tscn")
const ARMED_ANIMATION_PREFIX := &"armed"
const DEFAULT_FIRE_RATE_MULTIPLIER := 1.0
const SPIRAL_PHASE_STEP := PI / 6
const FOOTSTEP_DISTANCE := 32.0

var _footstep_distance: float = 0.0

# Four-direction moving animation.
@onready var _audio: Node = get_node("/root/AudioManager")
@onready var body_sprite: AnimatedSprite2D = $BodySprite

# 螺旋强化形态下额外显示的浮游炮特效。
@onready var armed_effect_sprite: AnimatedSprite2D = $ArmedEffectSprite
# 射击计时器，只负责限制开火频率。
@onready var shooting_timer: Timer = $ShootingTimer
@onready var buff_controller: BuffController = $BuffController

# Contemporary animation's suffix.
var facing_suffix: StringName = &"right"

# 普通射速倍率。
var rapid_fire_rate_multiplier: float = DEFAULT_FIRE_RATE_MULTIPLIER
# 强化形态自带的射速倍率。
var form_fire_rate_multiplier: float = DEFAULT_FIRE_RATE_MULTIPLIER
# 当前玩家形态。
var current_form_mode: PickupConfig.PlayerFormMode = PickupConfig.PlayerFormMode.NORMAL
# 当前弹幕模式。
var current_shot_pattern: PickupConfig.ShotPattern = PickupConfig.ShotPattern.NORMAL
# 螺旋弹幕的相位，用来让连续射击形成旋转感。
var spiral_phase: float = 0.0

# Player's speed, whose unit is pt/s.
@export var move_speed: float = 120.0

# 连续开火之间的最短间隔。
@export var fire_interval: float = 0.18
# 子弹生成时相对玩家的偏移距离，避免子弹出生在身体内部。
@export var bullet_spawn_distance: float = 18.0

func _ready() -> void:
	current_hp = max_hp
	add_to_group(&"players")
	shooting_timer.one_shot = true
	shooting_timer.wait_time = _get_effective_fire_interval()
	buff_controller.effects_changed.connect(_on_buff_effects_changed)
	_on_buff_effects_changed()


func apply_pickup(config: PickupConfig) -> bool:
	if is_dead:
		return false
	return buff_controller.apply_pickup(config)


func take_damage(amount: int) -> bool:
	if is_dead or amount <= 0 or invulnerability_remaining > 0.0:
		return false
	current_hp = maxi(current_hp - amount, 0)
	invulnerability_remaining = invulnerability_duration
	health_changed.emit(current_hp, max_hp)
	if current_hp == 0:
		is_dead = true
		velocity = Vector2.ZERO
		shooting_timer.stop()
		died.emit()
	else:
		_audio.play_sfx(&"player_hurt")
	return true


func _on_buff_effects_changed() -> void:
	var was_spiral := current_shot_pattern == PickupConfig.ShotPattern.SPIRAL
	rapid_fire_rate_multiplier = buff_controller.rapid_fire_rate_multiplier
	form_fire_rate_multiplier = buff_controller.form_fire_rate_multiplier
	current_form_mode = buff_controller.player_form_mode
	current_shot_pattern = buff_controller.shot_pattern
	if not was_spiral and current_shot_pattern == PickupConfig.ShotPattern.SPIRAL:
		spiral_phase = 0.0
	_update_animation()
	_update_armed_effect()

func _physics_process(delta: float) -> void:
	if is_dead:
		return
	invulnerability_remaining = maxf(invulnerability_remaining - delta, 0.0)
	modulate.a = 0.35 if invulnerability_remaining > 0.0 and int(invulnerability_remaining / 0.1) % 2 == 0 else 1.0
	buff_controller.tick(delta)
	# Receive input info and convert it into standardized eight-direction vectors.
	var move_input := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var shoot_input := Input.get_vector("shoot_left", "shoot_right", "shoot_up", "shoot_down")
	
	# Complete moving.
	velocity = move_input * move_speed * buff_controller.move_speed_multiplier
	var previous_position := global_position
	move_and_slide()
	_update_footsteps(previous_position.distance_to(global_position))
	
	if current_shot_pattern == PickupConfig.ShotPattern.SPIRAL:
		_try_auto_spiral_shoot()
	elif shoot_input != Vector2.ZERO:
		_try_shoot(shoot_input)
	
	_update_facing(move_input, shoot_input)
	_update_animation()
	_update_armed_effect()


func _update_footsteps(distance: float) -> void:
	if distance < 0.01:
		_footstep_distance = 0.0
		return
	_footstep_distance += distance
	if _footstep_distance >= FOOTSTEP_DISTANCE:
		if _audio.play_sfx(&"footstep"):
			_footstep_distance = fmod(_footstep_distance, FOOTSTEP_DISTANCE)
		else:
			_footstep_distance = FOOTSTEP_DISTANCE

func _update_animation() -> void:
	var animation_name := StringName("%s_%s" % [_get_animation_prefix(), facing_suffix])
	
	if not body_sprite.sprite_frames.has_animation(animation_name):
		var fallback_animation_name := StringName("%s_%s" % [NORMAL_ANIMATION_PREFIX, facing_suffix])
		if not body_sprite.sprite_frames.has_animation(fallback_animation_name):
			push_warning("Missing player animation: %s" % animation_name)
			return
		animation_name = fallback_animation_name
		
	if body_sprite.animation != animation_name:
		body_sprite.play(animation_name)
		
# 射击方向优先于移动方向，用于决定当前显示的角色朝向。
# 自动螺旋弹幕期间不再读取射击输入，而是仅按移动方向更新armed动画朝向。
func _update_facing(move_input: Vector2, shoot_input: Vector2) -> void:
	if current_shot_pattern == PickupConfig.ShotPattern.SPIRAL:
		if move_input != Vector2.ZERO:
			facing_suffix = _vector_to_facing_suffix(move_input)
		return	
	
	if shoot_input != Vector2.ZERO:
		facing_suffix = _vector_to_facing_suffix(shoot_input)
	elif move_input != Vector2.ZERO:
		facing_suffix = _vector_to_facing_suffix(move_input)
		
# 尝试发射子弹：先检查冷却，再根据当前弹幕模式发射。
func _try_shoot(shoot_input: Vector2) -> void:
	if not shooting_timer.is_stopped():
		return
	
	var shoot_direction := shoot_input.normalized()
	var has_spawned_bullet := _fire_bullets(shoot_direction)
	if has_spawned_bullet:
		shooting_timer.start(_get_effective_fire_interval())
		
func _try_auto_spiral_shoot() -> void:
	if not shooting_timer.is_stopped():
		return

	if _fire_bullets(Vector2.ZERO):
		shooting_timer.start(_get_effective_fire_interval())

# 根据当前弹幕模式发射子弹。螺旋模式每次推进一个固定相位。
func _fire_bullets(shoot_direction: Vector2) -> bool:
	if is_dead:
		return false
	var bullet_direction := shoot_direction
	if current_shot_pattern == PickupConfig.ShotPattern.SPIRAL:
		bullet_direction = Vector2.RIGHT.rotated(spiral_phase)

	if bullet_direction == Vector2.ZERO:
		return false

	if not _spawn_bullet(bullet_direction):
		return false
	_audio.play_sfx(&"shot")
	if current_shot_pattern == PickupConfig.ShotPattern.SPIRAL:
		spiral_phase = fposmod(spiral_phase + SPIRAL_PHASE_STEP, TAU)
	return true

# 实例化子弹并放到当前场景根节点，避免子弹随玩家移动。
func _spawn_bullet(direction: Vector2) -> bool:
	var bullet := BULLET_SCENE.instantiate() as Bullet
	if bullet == null:
		push_error("Could not instantiate the bullet scene.")
		return false

	var bullet_parent: Node = get_tree().current_scene
	if bullet_parent == null:
		bullet_parent = get_parent()
	if bullet_parent == null:
		push_error("Could not find a parent for the bullet.")
		bullet.queue_free()
		return false

	bullet_parent.add_child(bullet)
	bullet.setup(direction)
	bullet.global_position = global_position + bullet.direction * bullet_spawn_distance
	return true

func _get_animation_prefix() -> StringName:
	return ARMED_ANIMATION_PREFIX if current_form_mode == PickupConfig.PlayerFormMode.ARMED else NORMAL_ANIMATION_PREFIX

func _update_armed_effect() -> void:
	armed_effect_sprite.visible = current_form_mode == PickupConfig.PlayerFormMode.ARMED
	if armed_effect_sprite.visible and armed_effect_sprite.sprite_frames.has_animation(&"default"):
		if armed_effect_sprite.animation != &"default" or not armed_effect_sprite.is_playing():
			armed_effect_sprite.play(&"default")

func _get_effective_fire_interval() -> float:
	return maxf(fire_interval, 0.01) / rapid_fire_rate_multiplier / form_fire_rate_multiplier

func _vector_to_facing_suffix(direction: Vector2) -> StringName:
	if abs(direction.x) >= abs(direction.y):
		return &"right" if direction.x > 0.0 else &"left"
	return &"down" if direction.y > 0.0 else &"up"
	
