extends RefCounted

func _place(view: WorldView, distance: float = 1.2, armed: bool = false) -> void:
	for slot in 2:
		var player: PlayerState = view.simulation.players[slot]
		player.reset(1)
		player.position = Vector3(-8, 0.002, -3 - slot * distance)
		player.movement.grounded = true
		player.yaw = PI if slot == 1 else 0.0
		view.simulation.queries.proxies[slot].position = player.position
		if armed:
			player.inventory.weapons[0] = {"id": 900 + slot, "kind": 1, "magazine": 24, "next_shot_us": 0}
			player.inventory.active_slot = 0

func test_melee_impulses_and_sprint(a: DuelAssertions) -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var config := GameConfig.new()
	config.load_data()
	var view := WorldView.new()
	tree.root.add_child(view)
	view.build(config)
	var first := InputFrame.new()
	first.actions = [{"kind": "melee"}]
	var second := InputFrame.new()
	second.yaw = PI
	for armed in [false, true]:
		_place(view, 1.2, armed)
		await tree.physics_frame
		view.simulation.step([first, second], 1)
		a.truth(absf(view.simulation.players[1].velocity.z + 5.0) < 0.001, "melee adds exactly 5 m/s for armed=%s" % armed)
		for player in view.simulation.players:
			a.equal([player.hp_milli, player.armor_milli], [100000, 50000], "melee has no damage")
	_place(view)
	second.actions = [{"kind": "melee"}]
	await tree.physics_frame
	view.simulation.step([first, second], 1)
	a.truth(absf(view.simulation.players[0].velocity.z - 5.0) < 0.001, "simultaneous first impulse")
	a.truth(absf(view.simulation.players[1].velocity.z + 5.0) < 0.001, "simultaneous second impulse")
	second.actions = []
	for distance in [1.6, 3.0]:
		_place(view, distance)
		await tree.physics_frame
		view.simulation.step([first, second], 1)
		a.equal(view.simulation.players[1].velocity.z, 0.0, "out of reach")
	_place(view)
	first.yaw = PI / 2
	await tree.physics_frame
	view.simulation.step([first, second], 1)
	a.equal(view.simulation.players[1].velocity.z, 0.0, "outside forward cone")
	first.yaw = 0
	var wall := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	shape.shape.size = Vector3(2, 2, 0.1)
	wall.add_child(shape)
	wall.position = Vector3(-8, 1, -3.6)
	view.add_child(wall)
	_place(view)
	await tree.physics_frame
	await tree.physics_frame
	view.simulation.step([first, second], 1)
	a.equal(view.simulation.players[1].velocity.z, 0.0, "wall blocks melee")
	wall.position.z = -4.7
	_place(view)
	await tree.physics_frame
	view.simulation.step([first, second], 1)
	first.actions = []
	for tick in range(2, 15): view.simulation.step([first, second], tick)
	a.truth(view.simulation.players[1].position.z >= -4.31, "impulse stops against wall")
	a.truth(absf(view.simulation.players[1].velocity.z) < 0.01, "wall removes inward velocity")
	wall.queue_free()
	_place(view, 3, true)
	first.held_buttons = InputFrame.SPRINT | InputFrame.FIRE
	first.axes = Vector2(0, -1)
	await tree.physics_frame
	view.simulation.step([first, second], 1)
	a.truth(not view.simulation.players[0].movement.sprinting, "fire cancels sprint")
	a.equal(view.simulation.players[0].inventory.active().magazine, 23, "fire during sprint emits bullet")
	view.queue_free()
	await tree.process_frame
