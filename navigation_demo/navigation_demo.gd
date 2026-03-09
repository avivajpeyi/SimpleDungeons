extends Node3D

var player_scene = preload("res://FPSController/FPSController.tscn")

@onready var dungeon_generator = %DungeonGenerator3D

func _ready():
	%DungeonGenerator3D.generate(randi())
	$GUI/PlayerButton.pressed.connect(_on_spawn_player_button_pressed)
	$GUI/PlayerButton.pressed.connect(func(): $NavigationUtil.set_path_depth_test(false))

var player
func _on_spawn_player_button_pressed():
	if player and is_instance_valid(player): return
	var spawn_points = get_tree().get_nodes_in_group("player_spawn_point")
	if spawn_points.size() == 0: return
	player = player_scene.instantiate()
	spawn_points.pick_random().add_child(player)
	for cam in player.find_children("*", "Camera3D"):
		cam.current = true
	$GUI.hide()
