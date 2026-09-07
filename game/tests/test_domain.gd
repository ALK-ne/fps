extends RefCounted

func test_armor(a: DuelAssertions) -> void:
	var rounds := [1, 3, 4, 7, 8, 11, 12]
	var expected := [50, 50, 75, 75, 100, 100, 125]
	for i in rounds.size(): a.equal(MatchReducer.armor_for_round(rounds[i]), expected[i], "armor round %d" % rounds[i])

func _created() -> MatchState:
	var reducer := MatchReducer.new()
	return reducer.apply(MatchState.new(), MatchEvent.make(1, {"match_id": DuelIds.random_bytes(16), "rule_hash": DuelIds.random_bytes(32), "players": [{"slot": 0}, {"slot": 1}], "epoch": 1})).value

func test_rounds_and_terminal(a: DuelAssertions) -> void:
	var s := _created()
	var reducer := MatchReducer.new()
	for round_number in 11:
		s = reducer.apply(s, MatchEvent.make(2, {"round": round_number + 1})).value
		s = reducer.apply(s, MatchEvent.make(3, {"round": round_number + 1})).value
		s = reducer.apply(s, MatchEvent.make(4, {"round": round_number + 1, "winner": -1 if round_number == 0 else 0})).value
		a.equal(s.round, round_number + 1, "round increments including draw")
	a.equal(s.scores, [10, 0], "ten wins")
	a.truth(s.is_terminal(), "terminal after ten")
	a.truth(not reducer.apply(s, MatchEvent.make(2, {"round": 12})).ok, "no eleventh win")

func test_recovery_receipt(a: DuelAssertions) -> void:
	var reducer := MatchReducer.new()
	var s := _created()
	s = reducer.apply(s, MatchEvent.make(2, {"round": 1})).value
	s = reducer.apply(s, MatchEvent.make(3, {"round": 1})).value
	s.scores = [9, 0]
	var event := MatchEvent.make(5, {"round": 1, "old_epoch": 1, "new_epoch": 2, "recovery_id": "one", "disposition": 0, "offender": 1})
	for i in 3:
		var r := reducer.apply(s, event)
		a.truth(r.ok, "recovery retry")
		s = r.value
	a.equal(s.scores, [10, 0], "single recovery point")
	a.equal(s.last_recovery_epoch, 1, "terminal retains receipt")
	a.equal(RecoveryCoordinator.identify_offender(true, false, 1), 0, "host restart evidence")
	a.equal(RecoveryCoordinator.identify_offender(true, true, -1), -1, "ambiguous restart")

func test_damage_and_draw(a: DuelAssertions) -> void:
	var players := [PlayerState.new(), PlayerState.new()]
	DamageSystem.apply(players, [{"target": 0, "amount": 150000}, {"target": 1, "amount": 150000}])
	a.equal(MatchReducer.decide_round(players, false), -1, "simultaneous death")
	players = [PlayerState.new(), PlayerState.new()]
	a.equal(MatchReducer.decide_round(players, true), -1, "timeout tie")
	DamageSystem.apply(players, [{"target": 1, "amount": 22500}])
	a.equal(players[1].armor_milli, 27500, "fractional headshot retained")
	a.equal(MatchReducer.decide_round(players, true), 0, "timeout total")

func test_codec(a: DuelAssertions) -> void:
	var data := {"a": 9223372036854775807, "b": [true, "日本語", -3], "c": Vector3(1, 2, 3)}
	var encoded := CanonicalCodec.encode(data)
	var decoded := CanonicalCodec.decode(encoded)
	a.truth(decoded.ok, "canonical decode")
	a.equal(decoded.value, data, "int64 exact")
	a.equal(CanonicalCodec.encode(decoded.value), encoded, "canonical byte equality")
	for i in encoded.size(): a.truth(not CanonicalCodec.decode(encoded.slice(0, i)).ok, "truncation %d" % i)
	var trailing := encoded.duplicate()
	trailing.append(0)
	a.truth(not CanonicalCodec.decode(trailing).ok, "trailing bytes")
	a.truth(not CanonicalCodec.decode(CanonicalCodec.encode(NAN)).ok, "NaN")

func test_selection_deadline(a: DuelAssertions) -> void:
	var cfg := GameConfig.new()
	a.truth(cfg.load_data().ok, "config manifest")
	var d := RoundDirector.new()
	d.config = cfg
	var prepared := d.begin_round(_created(), 5)
	a.truth(not prepared.payload.has("selection_seed"), "selection RNG seed stays host-only")
	d.activate(0)
	var phase_data := d.to_data()
	phase_data.round = 1
	phase_data.tick = 0
	a.truth(CanonicalCodec.decode(CanonicalCodec.encode(phase_data)).ok, "mixed String and StringName keys canonicalized")
	a.truth(not d.accept_spawn(d.first_slot, 0, d.revision, 600).ok, "deadline equality timeout")
	d.step(600)
	a.equal(d.phase, 3, "second selection after timeout")
	d.step(1200)
	a.equal(d.phase, 4, "countdown after twenty seconds")
	d.step(1380)
	a.equal(d.phase, 5, "fight after twenty three seconds")

func test_loot_caps(a: DuelAssertions) -> void:
	var cfg := GameConfig.new()
	cfg.load_data()
	for seed_value in 1000:
		var loot := LootBuilder.generate(cfg, seed_value)
		var guns := 0
		for item in loot:
			if item.kind == 1: guns += 1
		a.equal(guns, 10, "guaranteed guns seed %d" % seed_value)
	var inventory := Inventory.new()
	inventory.reserve[0] = 119
	var box := {"kind": 2, "subtype": 1, "amount": 24, "revision": 0}
	a.truth(inventory.add_pickup(box, cfg).ok, "partial ammo pickup")
	a.equal(inventory.reserve[0], 120, "reserve cap")
	a.equal(box.amount, 23, "remainder retained")
