extends RefCounted

func _reset(view: WorldView, position: Vector3 = Vector3.ZERO) -> PlayerState:
	var player: PlayerState = view.simulation.players[0]
	player.reset(1)
	player.position = position
	player.movement.grounded = true
	view.simulation.queries.proxies[0].position = position
	view.simulation.queries.proxies[1].position = Vector3(10, 0, 10)
	view.simulation.players[1].position = Vector3(10, 0, 10)
	return player

func _box(view: WorldView, position: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	shape.shape.size = size
	body.add_child(shape)
	body.position = position
	view.add_child(body)
	return body

func test_ground_slide_and_ceiling(a: DuelAssertions) -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var config := GameConfig.new()
	config.load_data()
	config.arena.obstacles = []
	var view := WorldView.new()
	tree.root.add_child(view)
	view.build(config)
	await tree.physics_frame
	await tree.physics_frame
	for direction in [Vector2(0, -1), Vector2(1, -1)]:
		for mode in [[0, 6.0], [InputFrame.SPRINT, 10.0], [InputFrame.CROUCH, 3.0]]:
			var player := _reset(view)
			var frame := InputFrame.new()
			frame.axes = direction
			frame.held_buttons = int(mode[0])
			for tick in 30: player.movement = view.simulation.movement.step(player, frame)
			a.truth(absf(Vector2(player.velocity.x, player.velocity.z).length() - float(mode[1])) < 0.01, "ground mode speed and diagonal normalization")
	var player := _reset(view)
	player.velocity = Vector3(0, 0, -10)
	var slide := InputFrame.new()
	slide.axes = Vector2(0, -1)
	slide.held_buttons = InputFrame.SPRINT | InputFrame.CROUCH
	player.movement = view.simulation.movement.step(player, slide)
	a.equal(player.movement.slide_remaining_ticks, 41, "first of 42 slide ticks")
	for tick in 41: player.movement = view.simulation.movement.step(player, slide)
	a.equal(player.movement.slide_remaining_ticks, 0, "slide ends at tick 42")
	for tick in 20: player.movement = view.simulation.movement.step(player, slide)
	a.truth(absf(player.velocity.z + 3.0) < 0.01, "held crouch returns to crouch speed after slide")
	var ceiling := _box(view, Vector3(0, 1.45, 0), Vector3(3, 0.2, 3))
	player = _reset(view)
	player.movement.crouched = true
	await tree.physics_frame
	await tree.physics_frame
	var neutral := InputFrame.new()
	player.movement = view.simulation.movement.step(player, neutral)
	a.truth(player.movement.crouched, "cannot stand through low ceiling")
	ceiling.queue_free()
	await tree.physics_frame
	player.movement = view.simulation.movement.step(player, neutral)
	a.truth(not player.movement.crouched, "stands after overhead space clears")
	for airborne in [false, true]:
		player = _reset(view)
		player.movement.grounded = not airborne
		player.movement.slide_remaining_ticks = 0 if airborne else 20
		player.inventory.weapons[0] = {"id": 901, "kind": 1, "magazine": 24, "next_shot_us": 0}
		player.inventory.active_slot = 0
		var fire := InputFrame.new()
		fire.held_buttons = InputFrame.FIRE
		view.simulation.weapons.fire(player, fire, 100)
		a.equal(player.inventory.active().magazine, 23, "airborne/slide fire is allowed")
	view.queue_free()
	await tree.process_frame

func test_vault_geometry(a: DuelAssertions) -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var config := GameConfig.new()
	config.load_data()
	config.arena.obstacles = []
	var view := WorldView.new()
	tree.root.add_child(view)
	view.build(config)
	var wall := _box(view, Vector3(0, 0.3, -1.0), Vector3(3, 0.6, 0.4))
	var player := _reset(view)
	await tree.physics_frame
	await tree.physics_frame
	a.truth(view.simulation.queries.vault_destination(0, player).ok, "low thin wall has landing space")
	var jump := InputFrame.new()
	jump.actions = [{"kind": "jump"}]
	player.movement = view.simulation.movement.step(player, jump)
	a.truth(player.movement.vaulting, "vault takes priority over jump")
	var end := player.movement.vault_end
	var neutral := InputFrame.new()
	for tick in 18: player.movement = view.simulation.movement.step(player, neutral)
	a.truth(not player.movement.vaulting and player.position.distance_to(end) < 0.08, "vault reaches endpoint in 18 ticks without penetration: %s -> %s" % [player.position, end])
	player = _reset(view)
	player.movement = view.simulation.movement.step(player, jump)
	for tick in 6: player.movement = view.simulation.movement.step(player, neutral)
	view.simulation.queries.proxies[1].position = Vector3(0, 0.62, -1.2)
	await tree.physics_frame
	for tick in 18: player.movement = view.simulation.movement.step(player, neutral)
	a.truth(not player.movement.vaulting and player.position.z >= -0.51, "opponent entering route blocks vault without penetration")
	(wall.get_child(0).shape as BoxShape3D).size.z = 2.0
	wall.position.z = -1.8
	player = _reset(view)
	await tree.physics_frame
	await tree.physics_frame
	a.truth(not view.simulation.queries.vault_destination(0, player).ok, "wall deeper than 1.2 m is rejected")
	(wall.get_child(0).shape as BoxShape3D).size.z = 0.4
	for height in [0.4, 1.3]:
		(wall.get_child(0).shape as BoxShape3D).size.y = height
		wall.position = Vector3(0, height / 2, -1.0)
		await tree.physics_frame
		await tree.physics_frame
		a.truth(not view.simulation.queries.vault_destination(0, player).ok, "height outside vault limits")
	view.queue_free()
	await tree.process_frame

func test_vault_rejects_gameplay_actions(a: DuelAssertions) -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var config := GameConfig.new()
	config.load_data()
	config.arena.obstacles = []
	var view := WorldView.new()
	tree.root.add_child(view)
	view.build(config)
	var player := _reset(view)
	player.movement.vaulting = true
	player.hp_milli = 50000
	player.inventory.heals[0] = 1
	player.inventory.grenades[0] = 1
	player.inventory.weapons[0] = {"id": 901, "kind": 1, "magazine": 24, "next_shot_us": 0}
	player.inventory.active_slot = 0
	a.truth(not view.simulation.healing.begin(player, 1, 0).ok, "vault rejects healing")
	var fire := InputFrame.new()
	fire.held_buttons = InputFrame.FIRE
	view.simulation.weapons.fire(player, fire, 0)
	a.equal(player.inventory.active().magazine, 24, "vault rejects firing")
	player.action = CanonicalCodec.Action.GRENADE_AIM
	a.truth(not view.simulation.grenade.throw_from(player, 0).ok, "vault rejects grenade release")
	a.equal(player.inventory.grenades[0], 1, "rejected release preserves stock")
	player.action = CanonicalCodec.Action.IDLE
	view.simulation.pickup.items = [{"id": 999, "revision": 0, "kind": 3, "subtype": 1, "amount": 1, "position": player.eye() + Vector3.FORWARD * 0.8}]
	view.sync_items()
	await tree.physics_frame
	await tree.physics_frame
	var interact := InputFrame.new()
	interact.actions = [{"kind": "interact"}]
	a.truth(not view.simulation.pickup.target(player).is_empty(), "real pickup ray sees fixture")
	view.simulation.pickup.step(view.simulation.players, [interact, InputFrame.new()], 1, 1)
	a.equal(player.inventory.heals[0], 1, "vault rejects visible pickup")
	a.equal(view.simulation.pickup.items[0].amount, 1, "rejected pickup remains in world")
	view.simulation.pickup.items.clear()
	view.sync_items()
	_box(view, Vector3(0, 0.3, -1.0), Vector3(3, 0.6, 0.4))
	player = _reset(view)
	player.action = CanonicalCodec.Action.GRENADE_AIM
	player.inventory.grenades[0] = 1
	await tree.physics_frame
	await tree.physics_frame
	var simultaneous := InputFrame.new()
	simultaneous.actions = [{"kind": "throw"}, {"kind": "jump"}]
	view.simulation.step([simultaneous, InputFrame.new()], 1)
	a.truth(player.movement.vaulting, "simultaneous jump starts vault")
	a.equal(player.inventory.grenades[0], 1, "vault start blocks release in the same tick")
	view.queue_free()
	await tree.process_frame
