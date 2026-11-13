extends Node2D

const SURVIVAL_DURATION := 60.0

var remaining_time: float = SURVIVAL_DURATION
var is_round_over: bool = false
var _paused_before_audio_settings: bool = false

@onready var _audio: Node = get_node("/root/AudioManager")
@onready var player: Player = $Player
@onready var health_label: Label = $HUD/Health/Count
@onready var countdown: TextureProgressBar = $HUD/Countdown
@onready var game_over: ColorRect = $HUD/GameOver
@onready var result_title: Label = $HUD/GameOver/Center/Panel/Content/Title
@onready var restart_button: Button = $HUD/GameOver/Center/Panel/Content/Restart
@onready var audio_settings: Control = $HUD/AudioSettings


func _ready() -> void:
	player.health_changed.connect(_on_health_changed)
	player.died.connect(_on_player_died)
	restart_button.pressed.connect(restart_game)
	_on_health_changed(player.current_hp, player.max_hp)
	countdown.max_value = SURVIVAL_DURATION
	countdown.value = remaining_time
	audio_settings.opened.connect(_on_audio_settings_opened)
	audio_settings.closed.connect(_on_audio_settings_closed)
	_audio.start_round()


func _physics_process(delta: float) -> void:
	if is_round_over or get_tree().paused:
		return
	remaining_time = maxf(remaining_time - delta, 0.0)
	if is_zero_approx(remaining_time):
		remaining_time = 0.0
	countdown.value = remaining_time
	if remaining_time == 0.0:
		_end_game(player.current_hp > 0 and not player.is_dead)


func _on_health_changed(current_hp: int, _max_hp: int) -> void:
	health_label.text = "× %d" % current_hp


func _on_player_died() -> void:
	_end_game(false)


func _end_game(won: bool) -> void:
	if is_round_over:
		return
	is_round_over = true
	result_title.text = "胜利！" if won else "游戏结束"
	game_over.show()
	if not audio_settings.is_open():
		restart_button.grab_focus()
	_audio.finish_round(won)
	get_tree().paused = true


func restart_game() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()


func _on_audio_settings_opened() -> void:
	_paused_before_audio_settings = get_tree().paused
	_audio.set_gameplay_paused(true)
	get_tree().paused = true


func _on_audio_settings_closed() -> void:
	get_tree().paused = _paused_before_audio_settings or is_round_over
	_audio.set_gameplay_paused(get_tree().paused)
	if is_round_over:
		restart_button.grab_focus()


func _exit_tree() -> void:
	_audio.stop_round()
