extends RefCounted

func _sim() -> DuelSimulation:
	var cfg := GameConfig.new()
	cfg.load_data()
	var sim := DuelSimulation.new()
	sim.config = cfg
	for slot in 2:
		var p := PlayerState.new()
		p.slot = slot
		p.reset(1)
		sim.players.append(p)
	return sim

func _projectile() -> Dictionary:
	return {"id": 1, "owner": 0, "kind": 1, "position": SnapshotCodec.vector(Vector3.ZERO), "velocity": SnapshotCodec.vector(Vector3(0, 0, -100)), "spawnTick": 100, "expiryTick": 220, "shotId": 1, "pelletIndex": 0}

func test_correction_before_spawn_and_tombstone(a: DuelAssertions) -> void:
	var sim := _sim()
	var r := EntityReplica.new()
	r.reset(1)
	var correction := {"round": 1, "tick": 102, "requiredEventSeq": 1, "entities": [{"kind": 1, "id": 1, "position": SnapshotCodec.vector(Vector3(0, 0, -3)), "velocity": SnapshotCodec.vector(Vector3(0, 0, -100))}]}
	r.correction(correction, sim, 0)
	a.equal(sim.weapons.projectiles.size(), 0, "correction cannot create an entity")
	var event := EntityWire.tagged(1, {"shotId": 1, "weaponId": 10, "owner": 0, "recoilPitch": 0.0, "recoilYaw": 0.0, "projectiles": [_projectile()]})
	var message := {"round": 1, "firstEventSeq": 1, "serverTick": 100, "events": [event]}
	r.events(message, sim, 100)
	a.equal(sim.weapons.projectiles[0].position, Vector3(0, 0, -3), "queued correction applied after spawn")
	a.equal(r.notifications.size(), 1, "one confirmed shot notification")
	r.events(message, sim, 101)
	a.equal(r.notifications.size(), 1, "duplicate has no audio or spawn side effect")
	r.events({"round": 1, "firstEventSeq": 2, "serverTick": 103, "events": [EntityWire.tagged(2, {"id": 1, "reason": 1, "point": SnapshotCodec.vector(Vector3.ZERO), "normal": SnapshotCodec.vector(Vector3.UP)})]}, sim, 102)
	r.correction(correction, sim, 103)
	a.equal(sim.weapons.projectiles.size(), 0, "late correction cannot revive ended projectile")
	message.events[0].payload.weaponId = 11
	r.events(message, sim, 104)
	a.truth(r.conflict, "same event sequence with changed content is a conflict")

func test_baseline_hash_and_retries(a: DuelAssertions) -> void:
	var sim := _sim()
	var built := EntityWire.baseline(sim, 100, 1, 0)
	a.truth(built.ok, "typed baseline builds")
	var encoded := ControlWire.encode(24, built.value)
	a.truth(encoded.ok, "typed baseline serializes")
	a.truth(ControlWire.decode(24, encoded.value).ok, "baseline hash and semantic validation")
	var tampered: PackedByteArray = encoded.value.duplicate()
	tampered[25] ^= 1
	a.equal(ControlWire.decode(24, tampered).error_code, "INVALID_BASELINE_HASH", "payload mutation rejected before state change")
	var requester := BaselineRequester.new()
	requester.request(2)
	var first := requester.poll(1, 0, 100, 0)
	a.truth(not first.is_empty(), "initial request")
	a.truth(requester.poll(1, 0, 100, 1999).is_empty(), "no early retry")
	a.equal(requester.poll(1, 0, 100, 2000).requestId, first.requestId, "retry preserves request ID")
	requester.poll(1, 0, 100, 4000)
	requester.poll(1, 0, 100, 6000)
	a.truth(requester.failed, "finite failure after three sends")
