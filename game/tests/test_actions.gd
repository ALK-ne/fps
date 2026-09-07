extends RefCounted

func test_heal_completion_and_cancel(a: DuelAssertions) -> void:
	var cfg := GameConfig.new()
	cfg.load_data()
	var healing := HealingSystem.new()
	healing.config = cfg
	for kind in [1, 2, 3, 4]:
		var p := PlayerState.new()
		p.hp_milli = 40000
		p.armor_milli = 0
		p.inventory.heals[kind - 1] = 1
		a.truth(healing.begin(p, kind, 0).ok, "begin heal %d" % kind)
		var expected: int = [225, 375, 180, 300][kind - 1]
		a.equal(p.action_end_tick, expected, "heal deadline")
		a.truth(not healing.complete(p, expected - 1), "no early completion")
		a.equal(p.inventory.heals[kind - 1], 1, "reserved not consumed")
		a.truth(healing.complete(p, expected), "complete on deadline")
		a.equal(p.inventory.heals[kind - 1], 0, "consume exactly one")
		a.truth(not healing.complete(p, expected + 1), "no duplicate completion")
	var p := PlayerState.new()
	p.hp_milli = 1000
	p.inventory.heals[0] = 1
	healing.begin(p, 1, 0)
	p.hp_milli = 0
	a.truth(not healing.complete(p, 225), "death prevents heal")
	a.equal(p.inventory.heals[0], 1, "death does not consume")

func test_reload_conservation(a: DuelAssertions) -> void:
	var cfg := GameConfig.new()
	cfg.load_data()
	var system := WeaponSystem.new()
	system.config = cfg
	for kind in [1, 2, 3]:
		var p := PlayerState.new()
		p.inventory.weapons[0] = {"id": 1, "kind": kind, "magazine": 1, "next_shot_us": 0}
		p.inventory.active_slot = 0
		p.inventory.reserve[kind - 1] = 2
		a.truth(system.reload_begin(p, 0).ok, "reload begins")
		system.complete(p, p.action_end_tick - 1)
		a.equal(p.inventory.active().magazine, 1, "reload no early transfer")
		system.complete(p, p.action_end_tick)
		a.equal(p.inventory.active().magazine, 3, "limited reserve transfer")
		a.equal(p.inventory.reserve[kind - 1], 0, "reserve conserved")
		system.complete(p, p.action_end_tick + 1)
		a.equal(p.inventory.active().magazine, 3, "reload no duplicate")

func test_inventory_grenade_heal_caps(a: DuelAssertions) -> void:
	var cfg := GameConfig.new()
	cfg.load_data()
	var inv := Inventory.new()
	for kind in [1, 2]:
		var item := {"kind": 4, "subtype": kind, "amount": 1, "revision": 0}
		a.truth(inv.add_pickup(item, cfg).ok, "grenade pickup")
	var extra := {"kind": 4, "subtype": 1, "amount": 1, "revision": 0}
	a.truth(not inv.add_pickup(extra, cfg).ok, "combined grenade cap")
	a.equal(extra.amount, 1, "full inventory leaves ground item")
	for kind in [1, 2, 3, 4]:
		var cap: int = [4, 2, 4, 2][kind - 1]
		for i in cap:
			a.truth(inv.add_pickup({"kind": 3, "subtype": kind, "amount": 1, "revision": 0}, cfg).ok, "heal pickup")
		a.truth(not inv.add_pickup({"kind": 3, "subtype": kind, "amount": 1, "revision": 0}, cfg).ok, "heal kind cap")
	a.equal(inv.heals, [4, 2, 4, 2], "twelve heal total")
