extends Node
class_name BuffController

signal effects_changed

var move_speed_multiplier: float = 1.0
var rapid_fire_rate_multiplier: float = 1.0
var form_fire_rate_multiplier: float = 1.0
var player_form_mode: PickupConfig.PlayerFormMode = PickupConfig.PlayerFormMode.NORMAL
var shot_pattern: PickupConfig.ShotPattern = PickupConfig.ShotPattern.NORMAL

# 配置只保存效果定义；每个玩家独立保存时长和效果快照。
var _active_buffs: Dictionary = {}


func apply_pickup(config: PickupConfig) -> bool:
	if not _is_valid_config(config):
		return false
	_active_buffs[config.pickup_type] = {
		"config": config.duplicate(),
		"remaining": config.duration,
	}
	_recalculate_effects()
	return true


# 由玩家在处理移动和射击前调用，暂停时不会推进。
func tick(delta: float) -> void:
	if not is_finite(delta) or delta <= 0.0:
		return
	var expired := false
	for pickup_type: int in _active_buffs.keys():
		var state: Dictionary = _active_buffs[pickup_type]
		state["remaining"] = maxf(float(state["remaining"]) - delta, 0.0)
		if state["remaining"] <= 0.0:
			_active_buffs.erase(pickup_type)
			expired = true
	if expired:
		_recalculate_effects()


func clear_buffs() -> void:
	_active_buffs.clear()
	_recalculate_effects()


func get_remaining_time(type: PickupConfig.PickupType) -> float:
	if not _active_buffs.has(type):
		return 0.0
	return float(_active_buffs[type]["remaining"])


func _is_valid_config(config: PickupConfig) -> bool:
	if config == null:
		return false
	if not PickupConfig.PickupType.values().has(config.pickup_type):
		return false
	if not PickupConfig.PlayerFormMode.values().has(config.player_form_mode):
		return false
	if not PickupConfig.ShotPattern.values().has(config.shot_pattern):
		return false
	return (
		is_finite(config.duration) and config.duration > 0.0
		and is_finite(config.move_speed_multiplier) and config.move_speed_multiplier > 0.0
		and is_finite(config.fire_rate_multiplier) and config.fire_rate_multiplier > 0.0
	)


func _recalculate_effects() -> void:
	move_speed_multiplier = 1.0
	rapid_fire_rate_multiplier = 1.0
	form_fire_rate_multiplier = 1.0
	player_form_mode = PickupConfig.PlayerFormMode.NORMAL
	shot_pattern = PickupConfig.ShotPattern.NORMAL
	if _active_buffs.has(PickupConfig.PickupType.SPEED):
		var config := _active_buffs[PickupConfig.PickupType.SPEED]["config"] as PickupConfig
		move_speed_multiplier = config.move_speed_multiplier
	if _active_buffs.has(PickupConfig.PickupType.RAPID):
		var config := _active_buffs[PickupConfig.PickupType.RAPID]["config"] as PickupConfig
		rapid_fire_rate_multiplier = config.fire_rate_multiplier
	if _active_buffs.has(PickupConfig.PickupType.SPIRAL):
		var config := _active_buffs[PickupConfig.PickupType.SPIRAL]["config"] as PickupConfig
		form_fire_rate_multiplier = config.fire_rate_multiplier
		player_form_mode = config.player_form_mode
		shot_pattern = config.shot_pattern
	effects_changed.emit()
