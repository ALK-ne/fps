extends RefCounted

func test_camera_convergence_and_overflow(a: DuelAssertions) -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var cfg := GameConfig.new()
	cfg.load_data()
	cfg.arena.obstacles = []
	var view := WorldView.new()
	tree.root.add_child(view)
	view.build(cfg)
	var player := view.simulation.players[1]
	player.position = Vector3(-8, 0.02, -3)
	view.simulation.players[0].position = Vector3(8, 0.02, 3)
	await tree.physics_frame
	await tree.physics_frame
	var prediction := Prediction.new()
	var authoritative := Replication.player_data(player)
	authoritative.position += Vector3(0.2, 0, 0)
	prediction.reconcile(player, authoritative, view.simulation.movement)
	a.truth(prediction.camera_offset.distance_to(Vector3(-0.2, 0, 0)) < 0.001, "small correction preserves displayed eye")
	a.truth(prediction.advance_camera(0.05).distance_to(Vector3(-0.1, 0, 0)) < 0.001, "half correction after 50ms")
	a.equal(prediction.advance_camera(0.05), Vector3.ZERO, "camera converges exactly at 100ms")
	a.truth(not prediction.needs_baseline, "small open-space correction needs no baseline")
	authoritative = Replication.player_data(player)
	authoritative.position += Vector3(1.1, 0, 0)
	prediction.reconcile(player, authoritative, view.simulation.movement)
	a.equal(prediction.camera_offset, Vector3.ZERO, "large correction snaps")
	a.truth(prediction.needs_baseline, "large correction requests baseline")
	prediction.reset()
	player.inventory.weapons[0] = {"id": 1, "kind": 1, "magazine": 7, "next_shot_us": 0}
	player.inventory.active_slot = 0
	for i in 257:
		var frame := InputFrame.new()
		frame.seq = i + 1
		frame.held_buttons = InputFrame.FIRE
		frame.actions = [{"kind": "fire", "argument": 0}]
		prediction.predict(player, frame, view.simulation.movement)
	a.truth(prediction.overflow and prediction.needs_baseline, "257th unacknowledged frame requests resynchronization")
	a.equal(player.inventory.active().magazine, 7, "movement prediction cannot consume ammunition")
	view.queue_free()
	await tree.process_frame
