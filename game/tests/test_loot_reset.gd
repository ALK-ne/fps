extends RefCounted

func test_chance_extremes_and_round_reset(a: DuelAssertions) -> void:
	var config := GameConfig.new()
	config.load_data()
	for chance in [0.0, 1.0]:
		config.arena.weaponSlots.ammoChance = chance
		config.arena.healChance = chance
		config.arena.grenadeChance = chance
		var items := LootBuilder.generate(config, 99)
		var counts := [0, 0, 0, 0]
		for item in items:
			counts[int(item.kind) - 1] += 1
			if item.kind == 2:
				var gun: Dictionary = items.filter(func(candidate): return candidate.id == item.id - 1)[0]
				a.equal(item.subtype, gun.subtype, "ammo box matches independent weapon roll")
		a.equal(counts, [10, 10, 8, 4] if chance == 1 else [10, 0, 0, 0], "chance 0/1 applies to every optional slot")
	var tree: SceneTree = Engine.get_main_loop()
	var view := WorldView.new()
	tree.root.add_child(view)
	view.build(config)
	var sim := view.simulation
	sim.reset_round(1, [0, 3], 99)
	await tree.physics_frame
	var player := sim.players[0]
	a.truth(player.inventory.add_pickup(sim.pickup.items[0], config).ok, "equip generated weapon")
	var fire := InputFrame.new()
	fire.held_buttons = InputFrame.FIRE
	sim.weapons.fire(player, fire, 1)
	a.truth(not sim.weapons.projectiles.is_empty(), "real projectile active before reset")
	player.inventory.grenades[0] = 1
	player.action = CanonicalCodec.Action.GRENADE_AIM
	a.truth(sim.grenade.throw_from(player, 1).ok, "real grenade active before reset")
	player.inventory.heals[0] = 2
	player.inventory.reserve[0] = 100
	player.hp_milli = 1000
	player.pitch = 0.7
	player.action_kind = 3
	player.action_target = 99
	player.action_revision = 7
	sim.reset_round(4, [2, 5], 100)
	a.equal(player.hp_milli, 100000, "new round restores health")
	a.equal(player.armor_milli, 75000, "round number determines armor")
	a.equal(player.inventory.weapons, [null, null], "new round starts unarmed")
	a.equal(player.inventory.reserve, [0, 0, 0], "reserve cleared")
	a.equal(player.inventory.heals, [0, 0, 0, 0], "healing stock cleared")
	a.equal(player.inventory.grenades, [0, 0], "grenade stock cleared")
	a.equal([player.pitch, player.action_kind, player.action_target, player.action_revision], [0.0, 0, 0, 0], "old aiming and action metadata cleared")
	a.truth(sim.weapons.projectiles.is_empty() and sim.grenade.grenades.is_empty(), "old active entities cleared")
	a.equal(sim.pickup.items.size(), 32, "optional slots rerolled only for new round")
	view.queue_free()
	await tree.process_frame
