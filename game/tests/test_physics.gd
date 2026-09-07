extends RefCounted

func test_movement_and_projectiles(a: DuelAssertions) -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var cfg := GameConfig.new()
	cfg.load_data()
	var view := WorldView.new()
	tree.root.add_child(view)
	view.build(cfg)
	view.simulation.reset_round(1, [0, 3], 42)
	view.sync_items()
	var snapshot := Replication.world_data(view.simulation, 0)
	var bytes := CanonicalCodec.encode(snapshot)
	var decoded := CanonicalCodec.decode(bytes)
	a.truth(decoded.ok, "world baseline decodes")
	a.equal(CanonicalCodec.encode(decoded.value), bytes, "world baseline canonical bytes")
	await tree.physics_frame
	await tree.physics_frame
	var player := view.simulation.players[0]
	player.position = Vector3(-8, 0.05, 0)
	view.simulation.queries.proxies[0].position = player.position
	var neutral := InputFrame.new()
	for i in 10:
		player.movement = view.simulation.movement.step(player, neutral)
	a.truth(player.movement.grounded, "capsule rests on floor")
	var jump := InputFrame.new()
	jump.actions = [{"kind": "jump"}]
	player.movement = view.simulation.movement.step(player, jump)
	var peak := 0.0
	for i in 60:
		player.movement = view.simulation.movement.step(player, neutral)
		peak = maxf(peak, player.position.y)
	a.truth(peak > 1.2 and peak < 1.45, "jump apex around 1.33 m: %.3f" % peak)
	a.truth(player.movement.grounded, "jump lands")
	player.position = Vector3(-8, 0.02, -3)
	player.yaw = 0
	player.pitch = 0.04
	player.inventory.weapons[0] = {"id": 100, "kind": 1, "magazine": 24, "next_shot_us": 0}
	player.inventory.active_slot = 0
	var target := view.simulation.players[1]
	target.position = Vector3(-8, 0.02, -6)
	view.simulation.queries.proxies[0].position = player.position
	view.simulation.queries.proxies[1].position = target.position
	await tree.physics_frame
	var fire := InputFrame.new()
	fire.held_buttons = InputFrame.FIRE | InputFrame.ADS
	var shot_ticks: Array = []
	for i in 67:
		view.simulation.weapons.events.clear()
		player.recoil = Vector2.ZERO
		view.simulation.weapons.fire(player, fire, i)
		if not view.simulation.weapons.events.is_empty(): shot_ticks.append(i)
		var damage := view.simulation.weapons.step(i)
		DamageSystem.apply(view.simulation.players, damage)
	a.equal(shot_ticks.slice(0, 10), [0, 7, 14, 20, 27, 33, 40, 47, 53, 60], "rifle fractional tick cadence")
	a.truth(target.hp_milli < 100000, "swept projectiles damage real hitbox")
	var occluded := view.simulation.queries.ray(Vector3(-3, 1.5, 0), Vector3(3, 1.5, 0))
	a.truth(not occluded.is_empty(), "central wall blocks shots")
	view.queue_free()
	await tree.process_frame
