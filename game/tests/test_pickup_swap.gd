extends RefCounted

func _view() -> WorldView:
	var config := GameConfig.new()
	config.load_data()
	config.arena.obstacles = []
	var view := WorldView.new()
	Engine.get_main_loop().root.add_child(view)
	view.build(config)
	view.simulation.players[1].position = Vector3(10, 0, 10)
	view.simulation.queries.proxies[1].position = Vector3(10, 0, 10)
	return view

func _frame(press: bool = false) -> InputFrame:
	var frame := InputFrame.new()
	frame.held_buttons = InputFrame.INTERACT
	if press: frame.actions = [{"kind": "interact"}]
	return frame

func _equip(player: PlayerState) -> void:
	player.inventory.weapons = [{"id": 1 + player.slot * 10, "kind": 1, "magazine": 7}, {"id": 2 + player.slot * 10, "kind": 2, "magazine": 4}]
	player.inventory.active_slot = 0

func test_swap_duration_release_and_cancel(a: DuelAssertions) -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var view := _view()
	var sim := view.simulation
	var player: PlayerState = sim.players[0]
	_equip(player)
	var item := {"id": 910, "revision": 0, "kind": 1, "subtype": 3, "amount": 1, "position": player.eye() + Vector3.FORWARD * 0.8, "weapon": {"id": 910, "kind": 3, "magazine": 12}}
	sim.pickup.items = [item]
	view.sync_items()
	await tree.physics_frame
	await tree.physics_frame
	a.equal(sim.pickup.target(player).get("id"), 910, "real eye ray targets gun")
	sim.pickup.step(sim.players, [_frame(true), InputFrame.new()], 0, 1)
	a.equal(player.action, CanonicalCodec.Action.SWAP, "press starts full-inventory swap")
	sim.pickup.step(sim.players, [_frame(), InputFrame.new()], 59, 1)
	a.equal(player.inventory.active().id, 1, "999ms has no completed swap")
	var events := sim.pickup.step(sim.players, [_frame(true), InputFrame.new()], 60, 1)
	a.equal(events.size(), 1, "1000ms commits once despite duplicate press")
	a.equal(player.inventory.active().id, 910, "new gun equipped")
	var dropped: Dictionary = sim.pickup.items[1]
	a.equal([dropped.id, dropped.weapon.magazine], [1, 7], "drop preserves identity and partial magazine")
	a.truth(dropped.position.distance_to(Vector3(0, 0.35, -0.7)) < 0.01, "drop projected onto floor ahead")
	view.sync_items()
	player.pitch = -atan2(1.27, 0.7)
	await tree.physics_frame
	await tree.physics_frame
	a.equal(sim.pickup.target(player).get("id"), 1, "real ray can target dropped gun")
	sim.pickup.step(sim.players, [_frame(true), InputFrame.new()], 61, 1)
	a.equal(player.action, CanonicalCodec.Action.IDLE, "held E cannot reacquire drop")
	sim.pickup.step(sim.players, [InputFrame.new(), InputFrame.new()], 62, 1)
	sim.pickup.step(sim.players, [_frame(true), InputFrame.new()], 63, 1)
	a.equal(player.action, CanonicalCodec.Action.SWAP, "release and press arms new swap")
	player.pitch = 0
	sim.pickup.step(sim.players, [_frame(), InputFrame.new()], 123, 1)
	a.equal(player.inventory.active().id, 910, "looking away cancels without transfer")
	a.equal(player.action, CanonicalCodec.Action.IDLE, "gaze cancellation returns idle")
	player.pitch = -atan2(1.27, 0.7)
	sim.pickup.step(sim.players, [InputFrame.new(), InputFrame.new()], 124, 1)
	sim.pickup.step(sim.players, [_frame(true), InputFrame.new()], 125, 1)
	sim.pickup.step(sim.players, [InputFrame.new(), InputFrame.new()], 185, 1)
	a.equal(player.inventory.active().id, 910, "release at completion cancels swap")
	sim.pickup.step(sim.players, [_frame(true), InputFrame.new()], 186, 1)
	sim.pickup.step(sim.players, [_frame(), InputFrame.new()], 246, 1)
	a.equal([player.inventory.active().id, player.inventory.active().magazine], [1, 7], "released drop can be reacquired without refilling")
	view.queue_free()
	await tree.process_frame

func test_same_revision_priority(a: DuelAssertions) -> void:
	var tree: SceneTree = Engine.get_main_loop()
	for round_number in [1, 2]:
		for weapon in [false, true]:
			var view := _view()
			var sim := view.simulation
			for player in sim.players:
				player.position = Vector3(0, 0, 0.8 if player.slot == 0 else -0.8)
				player.yaw = 0 if player.slot == 0 else PI
				player.inventory.reserve[0] = 119
				if weapon: _equip(player)
			var item := {"id": 910, "revision": 0, "kind": 1 if weapon else 2, "subtype": 1, "amount": 1 if weapon else 24, "position": Vector3(0, 1.62, 0), "weapon": {"id": 910, "kind": 1, "magazine": 12}}
			sim.pickup.items = [item]
			view.sync_items()
			await tree.physics_frame
			await tree.physics_frame
			var events := sim.pickup.step(sim.players, [_frame(true), _frame(true)], 0, round_number)
			if weapon: events = sim.pickup.step(sim.players, [_frame(), _frame()], 60, round_number)
			var winner: int = (round_number - 1) % 2
			a.equal(events[0], {"kind": "pickup", "slot": winner}, "round alternates transaction priority")
			a.equal(events[1], {"kind": "action_rejected", "slot": 1 - winner, "reason": "STALE_ITEM"}, "loser receives stale revision result")
			if weapon:
				a.equal(sim.players[winner].inventory.active().id, 910, "one swap wins")
				a.equal(sim.pickup.items.size(), 2, "only winning gun is dropped")
			else:
				a.equal(sim.players[winner].inventory.reserve[0], 120, "winner reaches reserve cap")
				a.equal(sim.players[1 - winner].inventory.reserve[0], 119, "loser cannot consume changed box this tick")
				a.equal(item.amount, 23, "box retains untransferred ammo")
			view.queue_free()
			await tree.process_frame

func test_wall_drop_search(a: DuelAssertions) -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var view := _view()
	var wall := StaticBody3D.new()
	var collider := CollisionShape3D.new()
	collider.shape = BoxShape3D.new()
	collider.shape.size = Vector3(4, 3, 0.2)
	wall.add_child(collider)
	wall.position = Vector3(0, 1.5, -0.5)
	view.add_child(wall)
	await tree.physics_frame
	await tree.physics_frame
	var position := view.simulation.queries.weapon_drop_position(view.simulation.players[0])
	a.truth(position.z > -0.1, "wall blocks forward drop and overlapping radial points")
	a.truth(absf(position.y - 0.35) < 0.01, "alternative point rests above floor")
	a.truth(Vector2(position.x, position.z).length() > 0.5, "safe radial point used before feet fallback")
	view.queue_free()
	await tree.process_frame
