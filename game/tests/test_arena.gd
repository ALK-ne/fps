extends RefCounted

const WIDTH := 77
const DEPTH := 53

func _cell(position: Vector3) -> Vector2i:
	return Vector2i(roundi((position.x + 19) * 2), roundi((position.z + 13) * 2))

func _position(cell: Vector2i) -> Vector3:
	return Vector3(cell.x * 0.5 - 19, 0.02, cell.y * 0.5 - 13)

func test_arena_paths_sightlines_and_loot(a: DuelAssertions) -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var config := GameConfig.new()
	config.load_data()
	var view := WorldView.new()
	tree.root.add_child(view)
	view.build(config)
	for slot in 2: view.simulation.queries.proxies[slot].position = Vector3(100 + slot * 2, 0, 100)
	await tree.physics_frame
	await tree.physics_frame
	var space := view.get_world_3d().direct_space_state
	var shape := CapsuleShape3D.new()
	shape.radius = 0.35
	shape.height = 1.8
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.collision_mask = 1
	query.margin = 0.001
	var walkable: Dictionary = {}
	for x in WIDTH:
		for z in DEPTH:
			var cell := Vector2i(x, z)
			query.transform.origin = _position(cell) + Vector3.UP * 0.9
			if space.intersect_shape(query, 1).is_empty(): walkable[cell] = true
	var symmetric := true
	for cell: Vector2i in walkable:
		if not walkable.has(Vector2i(WIDTH - 1 - cell.x, cell.y)): symmetric = false
	a.truth(symmetric, "actual capsule clearance is left-right symmetric")
	for start in 6:
		var root_cell := _cell(view.arena.spawn_position(start))
		a.truth(walkable.has(root_cell), "spawn capsule fits")
		var queue: Array[Vector2i] = [root_cell]
		var parents: Dictionary = {root_cell: root_cell}
		var distances: Dictionary = {root_cell: 0}
		var cursor := 0
		while cursor < queue.size():
			var cell := queue[cursor]
			cursor += 1
			for direction in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				var next: Vector2i = cell + direction
				if not walkable.has(next) or parents.has(next): continue
				parents[next] = cell
				distances[next] = int(distances[cell]) + 1
				queue.append(next)
		a.truth(not config.spawn_pairs[start].is_empty(), "every first spawn has a legal opponent")
		for opponent in config.spawn_pairs[start]:
			var other := int(opponent)
			var goal := _cell(view.arena.spawn_position(other))
			a.truth(parents.has(goal), "legal spawn pair connected in physical grid")
			if not parents.has(goal): continue
			a.truth(int(distances[goal]) * 0.5 >= 20, "legal pair walking distance at least 20 m")
			for eye in [0.8, 1.62]:
				for target in [0.8, 1.62]:
					a.truth(not view.simulation.queries.ray(view.arena.spawn_position(start) + Vector3.UP * eye, view.arena.spawn_position(other) + Vector3.UP * target).is_empty(), "legal pair head/body sightline occluded")
			var path: Array[Vector2i] = [goal]
			while path.back() != root_cell: path.append(parents[path.back()])
			path.reverse()
			var state := MovementState.new()
			state.position = _position(root_cell)
			var traversed := true
			for cell in path:
				var target := _position(cell)
				state = view.simulation.queries.move_body(0, state, target - state.position)
				if state.position.distance_to(target) > 0.08:
					traversed = false
					break
			a.truth(traversed, "actual body sweep traverses path %d to %d" % [start, other])
	config.arena.weaponSlots.ammoChance = 1.0
	config.arena.healChance = 1.0
	config.arena.grenadeChance = 1.0
	for item in LootBuilder.generate(config, 42):
		var sphere := SphereShape3D.new()
		sphere.radius = 0.3 if item.kind == 1 else 0.2
		query.shape = sphere
		query.transform.origin = item.position
		a.truth(space.intersect_shape(query, 1).is_empty(), "every loot candidate clears static geometry")
	for obstacle in config.arena.obstacles:
		if float(obstacle.size[1]) > 1.2: continue
		var top := ArenaBuilder.vec(obstacle.position) + Vector3.UP * (float(obstacle.size[1]) / 2 + 0.02)
		a.truth(view.simulation.queries.standing_clear(0, top), "low platform has standing space")
	for direction in [Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK]:
		var state := MovementState.new()
		state.position = direction * (19 if direction.x != 0 else 13) + Vector3.UP * 1.33
		state = view.simulation.queries.move_body(0, state, direction * 3)
		a.truth(absf(state.position.x) <= 19.41 and absf(state.position.z) <= 13.41, "boundary contains capsule even at jump apex")
	view.queue_free()
	await tree.process_frame
