extends Node3D

@export var dungeon_generator: DungeonGenerator3D
@export var start_room: DungeonRoom3D
@export var end_room: DungeonRoom3D



var room_neighbors: Dictionary = {}  # { room: [neighbors] }
var rooms_by_floor: Dictionary = {}  # { y_level: [rooms_on_floor] }

# Canonical room list — real scene nodes from find_children, used as stable dict keys.
# get_all_placed_and_preplaced_rooms() / get_room_at_pos() may return stale virtual instances
# after finalization, so we normalize all references through this name→room lookup.
var _all_rooms: Array = []
var _room_by_name: Dictionary = {}  # { StringName: DungeonRoom3D }

var _path_mesh_instance: Node3D = null

func _ready():
	dungeon_generator.done_generating.connect(_on_dungeon_generated)

func _on_dungeon_generated():
	print("\n========== NAVIGATION SYSTEM ==========\n")

	build_neighbor_graph()
	print_graph_ascii()
	test_pathfinding()

#######################
## STEP 1: BUILD GRAPH
#######################

func build_neighbor_graph():
	"""Build room adjacency graph using scene-tree nodes as canonical references."""
	room_neighbors.clear()
	rooms_by_floor.clear()
	_room_by_name.clear()

	# find_children returns the actual spawned scene nodes, unlike
	# get_all_placed_and_preplaced_rooms() which may still hold stale virtual instances
	# that were queue_freed during finalization but not yet replaced in the quick lookup dicts.
	_all_rooms = dungeon_generator.find_children("*", "DungeonRoom3D", true)

	for room in _all_rooms:
		_room_by_name[room.name] = room
		room_neighbors[room] = []
		var floor_y = room.get_grid_pos().y
		if not rooms_by_floor.has(floor_y):
			rooms_by_floor[floor_y] = []
		rooms_by_floor[floor_y].append(room)

	for room in _all_rooms:
		for door in room.get_doors():
			var connected = door.get_room_leads_to()
			if connected == null:
				continue
			# Normalize: connected may be a stale virtual — look up by name to get the real node
			var canonical: DungeonRoom3D = _room_by_name.get(connected.name)
			if canonical and canonical not in room_neighbors[room]:
				room_neighbors[room].append(canonical)

	print("Graph built: %d rooms, %d floors" % [_all_rooms.size(), rooms_by_floor.size()])

func _canonical(room: DungeonRoom3D) -> DungeonRoom3D:
	"""Return the canonical scene-node reference for a room, resolving stale virtuals by name."""
	if room == null:
		return null
	return _room_by_name.get(room.name, room)

func print_graph_ascii():
	"""Print room graph as ASCII."""
	print("\nROOM GRAPH:")
	print("-".repeat(60))

	for room in room_neighbors.keys():
		var neighbors = room_neighbors[room]
		var room_pos = room.get_grid_pos()
		var neighbor_names = neighbors.map(func(n): return n.name)
		print("  [%s] @ (%d,%d,%d) -> %s" % [room.name, room_pos.x, room_pos.y, room_pos.z, neighbor_names])

	print("\nFLOORS:")
	for floor_y in rooms_by_floor.keys():
		var room_names = rooms_by_floor[floor_y].map(func(r): return r.name)
		print("  Floor %d: %s" % [floor_y, room_names])

	print("-".repeat(60) + "\n")

#######################
## STEP 2: PATHFINDING
#######################

func find_path_bfs(start: DungeonRoom3D = null, end: DungeonRoom3D = null) -> Array[DungeonRoom3D]:
	"""BFS shortest path between two rooms.
	If start or end are null, defaults to first and last rooms in the dungeon."""

	if _all_rooms.is_empty():
		return []
	var from := _canonical(start) if start else _all_rooms[0] as DungeonRoom3D
	var to   := _canonical(end)   if end   else _all_rooms[-1] as DungeonRoom3D

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
	"""Find room path between two world-space positions.
	Handles multi-floor dungeons by routing through stair rooms."""

	var start_grid = Vector3i((start_voxel / dungeon_generator.voxel_scale).floor())
	var end_grid   = Vector3i((end_voxel   / dungeon_generator.voxel_scale).floor())

	var from := _canonical(dungeon_generator.get_room_at_pos(start_grid))
	var to   := _canonical(dungeon_generator.get_room_at_pos(end_grid))

	if from == null:
		push_warning("Start voxel not in any room!")
		return []
	if to == null:
		push_warning("End voxel not in any room!")
		return []

	print("Finding path from %s to %s" % [from.name, to.name])

	var start_floor = from.get_grid_pos().y
	var end_floor   = to.get_grid_pos().y

	if start_floor != end_floor:
		print("  (Different floors: %d -> %d)" % [start_floor, end_floor])
		var staircase = find_nearest_staircase(from, end_floor)
		if staircase == null:
			push_warning("No staircase found connecting floor %d to floor %d!" % [start_floor, end_floor])
			return []
		var path_to_stairs   = find_path_bfs(from, staircase)
		var path_from_stairs = find_path_bfs(staircase, to)
		var result: Array[DungeonRoom3D] = []
		result.assign(path_to_stairs.slice(0, -1) + path_from_stairs)
		return result

	return find_path_bfs(from, to)

func find_nearest_staircase(current_room: DungeonRoom3D, target_floor: int) -> DungeonRoom3D:
	"""BFS to find the nearest stair room that connects to target_floor."""

	var queue: Array = [current_room]
	var visited: Dictionary = { current_room: true }

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
	"""Pretty-print a path."""
	if path.is_empty():
		print("  No path found!\n")
		return

	print("  Path found (%d rooms):" % path.size())
	for i in range(path.size()):
		var room = path[i]
		var pos = room.get_grid_pos()
		var marker = "->" if i < path.size() - 1 else "[END]"
		print("    %d. %s @ (%d,%d,%d) %s" % [i + 1, room.name, pos.x, pos.y, pos.z, marker])
	print()

#######################
## TESTING
#######################

func test_pathfinding():
	"""Test pathfinding with first/last rooms, cross-floor, and exported start/end."""

	if _all_rooms.size() < 2:
		print("Not enough rooms to test pathfinding\n")
		return

	if start_room and end_room:
		print("Pathing from start_room -> end_room (%s -> %s)" % [start_room.name, end_room.name])
		var path = find_path_bfs(start_room, end_room)
		print_path(path)
		render_path(path)


@export var path_tube_radius: float = 0.15

func render_path(path: Array[DungeonRoom3D]):
	"""Draw the path as thick tubes between room centres using CylinderMesh per segment."""

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

		# Align the cylinder's Y axis with the segment direction
		var y_axis := (to - from).normalized()
		var x_axis := Vector3.UP.cross(y_axis)
		if x_axis.length_squared() < 0.001:
			x_axis = Vector3.RIGHT.cross(y_axis)
		x_axis = x_axis.normalized()
		var z_axis := x_axis.cross(y_axis).normalized()

		inst.global_transform = Transform3D(
			Basis(x_axis, y_axis, z_axis),
			(from + to) * 0.5
		)
