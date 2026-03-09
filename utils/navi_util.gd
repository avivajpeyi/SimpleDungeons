extends Node3D

@export var dungeon_generator: DungeonGenerator3D
@export var start_room: DungeonRoom3D
@export var end_room: DungeonRoom3D
@export var path_tube_radius: float = 0.15

var room_neighbors: Dictionary = {}
var rooms_by_floor: Dictionary = {}

var _all_rooms: Array = []
var _path_mesh_instance: Node3D = null


func _ready():
	dungeon_generator.done_generating.connect(_on_dungeon_generated)


func _on_dungeon_generated():
	build_neighbor_graph()
	print_graph_ascii()
	test_pathfinding()


func build_neighbor_graph():
	room_neighbors.clear()
	rooms_by_floor.clear()

	_all_rooms = dungeon_generator.get_all_placed_and_preplaced_rooms()

	for room in _all_rooms:
		room_neighbors[room] = []
		var floor_y = room.get_grid_pos().y
		if not rooms_by_floor.has(floor_y):
			rooms_by_floor[floor_y] = []
		rooms_by_floor[floor_y].append(room)

	for room in _all_rooms:
		for door in room.get_doors():
			var connected = door.get_room_leads_to()
			if connected and connected not in room_neighbors[room]:
				room_neighbors[room].append(connected)

	print("Nav graph: %d rooms, %d floors" % [_all_rooms.size(), rooms_by_floor.size()])


func print_graph_ascii():
	print("\nROOM GRAPH:")
	print("-".repeat(60))
	for room in room_neighbors.keys():
		var pos = room.get_grid_pos()
		var names = room_neighbors[room].map(func(n): return n.name)
		print("  [%s] @ (%d,%d,%d) -> %s" % [room.name, pos.x, pos.y, pos.z, names])
	print("\nFLOORS:")
	for floor_y in rooms_by_floor.keys():
		var names = rooms_by_floor[floor_y].map(func(r): return r.name)
		print("  Floor %d: %s" % [floor_y, names])
	print("-".repeat(60) + "\n")


func find_path_bfs(start: DungeonRoom3D = null, end: DungeonRoom3D = null) -> Array[DungeonRoom3D]:
	if _all_rooms.is_empty():
		return []

	var from := start if start else _all_rooms[0] as DungeonRoom3D
	var to   := end   if end   else _all_rooms[-1] as DungeonRoom3D

	if from == to:
		return [from]

	var queue: Array = [[from]]
	var visited: Dictionary = { from: true }

	while queue.size() > 0:
		var path: Array = queue.pop_front()
		var current: DungeonRoom3D = path[-1]

		for neighbor in room_neighbors.get(current, []):
			if neighbor == to:
				path.append(neighbor)
				var result: Array[DungeonRoom3D] = []
				result.assign(path)
				return result
			if not visited.get(neighbor, false):
				visited[neighbor] = true
				var new_path = path.duplicate()
				new_path.append(neighbor)
				queue.append(new_path)

	return []


func find_path_from_voxels(start_voxel: Vector3, end_voxel: Vector3) -> Array[DungeonRoom3D]:
	var from := dungeon_generator.get_room_at_pos(Vector3i((start_voxel / dungeon_generator.voxel_scale).floor()))
	var to   := dungeon_generator.get_room_at_pos(Vector3i((end_voxel   / dungeon_generator.voxel_scale).floor()))

	if from == null or to == null:
		push_warning("Voxel position not inside any room")
		return []

	var start_floor = from.get_grid_pos().y
	var end_floor   = to.get_grid_pos().y

	if start_floor != end_floor:
		var staircase = find_nearest_staircase(from, end_floor)
		if staircase == null:
			push_warning("No staircase connecting floor %d to %d" % [start_floor, end_floor])
			return []
		var result: Array[DungeonRoom3D] = []
		result.assign(find_path_bfs(from, staircase).slice(0, -1) + find_path_bfs(staircase, to))
		return result

	return find_path_bfs(from, to)


func find_nearest_staircase(from: DungeonRoom3D, target_floor: int) -> DungeonRoom3D:
	var queue: Array = [from]
	var visited: Dictionary = { from: true }

	while queue.size() > 0:
		var room: DungeonRoom3D = queue.pop_front()

		var door_floors: Dictionary = {}
		for door in room.get_doors():
			door_floors[door.exit_pos_grid.y] = true

		if door_floors.size() > 1 and target_floor in door_floors:
			return room

		for neighbor in room_neighbors.get(room, []):
			if not visited.get(neighbor, false):
				visited[neighbor] = true
				queue.append(neighbor)

	return null


func print_path(path: Array[DungeonRoom3D]):
	if path.is_empty():
		print("  No path found")
		return
	print("  Path (%d rooms):" % path.size())
	for i in range(path.size()):
		var pos = path[i].get_grid_pos()
		var marker = "->" if i < path.size() - 1 else "[END]"
		print("    %d. %s @ (%d,%d,%d) %s" % [i + 1, path[i].name, pos.x, pos.y, pos.z, marker])


func test_pathfinding():
	if _all_rooms.size() < 2 or not start_room or not end_room:
		return
	print("Path: %s -> %s" % [start_room.name, end_room.name])
	var path = find_path_bfs(start_room, end_room)
	print_path(path)
	render_path(path)


func render_path(path: Array[DungeonRoom3D]):
	if _path_mesh_instance:
		_path_mesh_instance.queue_free()
		_path_mesh_instance = null

	if path.size() < 2:
		return

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.BLACK
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true

	var container := Node3D.new()
	add_child(container)
	_path_mesh_instance = container

	for i in range(path.size() - 1):
		var from := path[i].global_position     + Vector3.UP * 2.0
		var to   := path[i + 1].global_position + Vector3.UP * 2.0

		var cyl := CylinderMesh.new()
		cyl.top_radius    = path_tube_radius
		cyl.bottom_radius = path_tube_radius
		cyl.height        = from.distance_to(to)

		var inst := MeshInstance3D.new()
		inst.mesh              = cyl
		inst.material_override = mat
		container.add_child(inst)

		var y_axis := (to - from).normalized()
		var x_axis := Vector3.UP.cross(y_axis)
		if x_axis.length_squared() < 0.001:
			x_axis = Vector3.RIGHT.cross(y_axis)
		x_axis = x_axis.normalized()

		inst.global_transform = Transform3D(
			Basis(x_axis, y_axis, x_axis.cross(y_axis).normalized()),
			(from + to) * 0.5
		)
