extends RefCounted

func test_frag_fuse_and_occlusion(a: DuelAssertions) -> void:
	var cfg := GameConfig.new()
	cfg.load_data()
	var tree: SceneTree = Engine.get_main_loop()
	var world := WorldView.new()
	tree.root.add_child(world)
	world.build(cfg)
	world.simulation.reset_round(1, [0, 3], 7)
	await tree.physics_frame
	await tree.physics_frame
	var system := world.simulation.grenade
	var players := world.simulation.players
	players[0].position = Vector3(-8, 0.02, 0)
	players[1].position = Vector3(-6, 0.02, 0)
	world.simulation.queries.proxies[0].position = players[0].position
	world.simulation.queries.proxies[1].position = players[1].position
	await tree.physics_frame
	system.grenades = [{"id": 1, "owner": 0, "kind": 1, "position": Vector3(-8, 0.15, 0), "velocity": Vector3.ZERO, "expiry_tick": 150}]
	a.equal(system.step(players, 149).size(), 0, "no explosion before fuse")
	var damage := system.step(players, 150)
	a.equal(system.grenades.size(), 0, "grenade removed on fuse")
	a.equal(damage.size(), 2, "both nearby players receive blast")
	if damage.size() == 2:
		a.truth(damage[0].amount <= 50000 and damage[0].amount > 45000, "self damage half")
		a.truth(damage[1].amount > 40000 and damage[1].amount < 65000, "distance falloff")
	players[1].position = Vector3(1, 0.02, 0)
	a.truth(not world.simulation.queries.explosion_visible(Vector3(-2.1, 0.2, 0), players[1]), "central wall blocks blast")
	world.queue_free()
	await tree.process_frame

func test_incendiary_ticks_and_cells(a: DuelAssertions) -> void:
	var cfg := GameConfig.new()
	cfg.load_data()
	var tree: SceneTree = Engine.get_main_loop()
	var world := WorldView.new()
	tree.root.add_child(world)
	world.build(cfg)
	world.simulation.reset_round(1, [0, 3], 7)
	await tree.physics_frame
	await tree.physics_frame
	var system := world.simulation.grenade
	var players := world.simulation.players
	players[0].position = Vector3(-8, 0.02, 0)
	players[1].position = Vector3(-7, 0.02, 0)
	system._ignite({"id": 2, "owner": 0, "position": Vector3(-8, 0.2, 0)}, 0)
	a.equal(system.flames.size(), 1, "floor creates flame")
	a.truth(system.flames[0].cells.size() <= 81, "bounded cells")
	a.equal(system.step(players, 14).size(), 0, "first tick after fifteen")
	var owner_total := 0
	var enemy_total := 0
	for tick in range(15, 301, 15):
		for event in system.step(players, tick):
			if event.target == 0: owner_total += event.amount
			else: enemy_total += event.amount
	a.equal(owner_total, 80000, "20 self ticks at four damage")
	a.equal(enemy_total, 160000, "20 enemy ticks at eight damage")
	a.equal(system.flames.size(), 0, "field expires")
	system._ignite({"id": 3, "owner": 0, "position": Vector3(0, -10, 0)}, 0)
	a.equal(system.flames.size(), 0, "no floor no flame")
	world.queue_free()
	await tree.process_frame
