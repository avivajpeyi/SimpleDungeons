extends Label

var player: Node3D
@onready var dungeon_generator = %DungeonGenerator3D
var last_grid_pos: Vector3i = Vector3i.ZERO

func _ready() -> void:
	text = ""

func set_player(p: Node3D) -> void:
	player = p

func _process(_delta: float) -> void:
	if not is_instance_valid(player) or not dungeon_generator:
		text = ""
		return
		
	var player_local: Vector3 = dungeon_generator.to_local(player.global_position)
	var current_grid_pos := Vector3i((player_local / dungeon_generator.voxel_scale + Vector3(dungeon_generator.dungeon_size) / 2.0).floor())
	
	if current_grid_pos != last_grid_pos:
		# potentially send a signal here if you want to trigger other updates when the player changes rooms
		last_grid_pos = current_grid_pos
		_update_display(current_grid_pos)

func _update_display(grid_pos: Vector3) -> void:
	var room_data = get_player_room_data(grid_pos)
	
	if room_data.is_empty():
		text = "Outside Dungeon Bounds\ngrid: %s\nlocal: %s\ndungeon_size: %s" % [
			grid_pos,
			dungeon_generator.to_local(player.global_position),
			dungeon_generator.dungeon_size
		]
	else:
		text = "ROOM: %s\nGRID: %s" % [
			room_data.room.name,
			room_data.grid_pos
		]

func get_player_room_data(grid_pos: Vector3) -> Dictionary:
	var room = dungeon_generator.get_room_at_pos(grid_pos)
	
	if not room:
		return {}
		
	return {
		"room": room,
		"grid_pos": room.get_grid_pos(),
		"bounds": room.get_grid_aabbi(false)
	}
