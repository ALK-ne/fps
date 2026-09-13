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

func test_event_batches_respect_bytes_and_count(a: DuelAssertions) -> void:
	var events: Array = []
	var cells: Array = []
	for index in 81: cells.append(SnapshotCodec.vector(Vector3(index % 9, 0, index / 9)))
	for id in range(1, 65): events.append(EntityWire.tagged(7, {"id": id, "owner": 0, "spawnTick": 100, "expiryTick": 400, "nextDamageTick": 115, "cells": cells}))
	var split := EventJournal.batches(events)
	a.truth(split.ok and split.value.size() > 1, "large events split below count limit")
	var sequence := 1
	for batch in split.value:
		var encoded := MessageCodec.encode(22, {"round": 1, "firstEventSeq": sequence, "serverTick": 100, "events": batch})
		a.truth(encoded.ok and encoded.value.size() <= 32768 and batch.size() <= 64, "actual encoded packet stays inside both limits")
		a.equal(batch[0].payload.id, sequence, "split preserves event ordering")
		sequence += batch.size()
	a.equal(sequence, 65, "no events dropped during split")
	events.clear()
	for index in 65: events.append(EntityWire.tagged(8, {"slot": 0}))
	split = EventJournal.batches(events)
	a.equal([split.value[0].size(), split.value[1].size()], [64, 1], "small events split at count cap")

func test_history_digest_and_replay_buffer_bounds(a: DuelAssertions) -> void:
	var sim := _sim()
	var replica := EntityReplica.new()
	replica.reset(1)
	for seq in range(1, 1026):
		replica.events({"round": 1, "firstEventSeq": seq, "serverTick": 100, "events": [EntityWire.tagged(8, {"slot": 0})]}, sim, 0)
	a.equal(replica.history.size(), 1024, "past comparison retains only latest 1024 hashes")
	a.truth(replica.history[1025] is PackedByteArray and replica.history[1025].size() == 32, "comparison entry is SHA256 rather than full payload")
	a.equal(replica.replay_events.size(), 1024, "baseline replay has independent count limit")
	replica.events({"round": 1, "firstEventSeq": 1, "serverTick": 100, "events": [EntityWire.tagged(8, {"slot": 1})]}, sim, 0)
	a.truth(not replica.conflict, "older duplicate outside digest window is a no-op")
	replica.reset(1)
	var baseline: Dictionary = EntityWire.baseline(sim, 100, 1, 0).value
	var cells: Array = []
	for index in 81: cells.append(SnapshotCodec.vector(Vector3(index % 9, 0, index / 9)))
	var event := EntityWire.tagged(7, {"id": 1, "owner": 0, "spawnTick": 100, "expiryTick": 400, "nextDamageTick": 115, "cells": cells})
	for seq in range(1, 321): replica.events({"round": 1, "firstEventSeq": seq, "serverTick": 100, "events": [event]}, sim, 0)
	a.truth(replica.replay_bytes <= 262144 and replica.replay_events.size() < 320, "large replay payloads evicted by byte budget")
	a.truth(not replica.install(baseline, sim), "baseline older than retained payloads cannot partially rewind")
	a.equal(replica.sequence, 320, "failed rewind preserves current event sequence")
	a.equal(replica.request_reason, 1, "requests a fresh baseline when replay range was evicted")

func test_generation_limits_do_not_consume_inventory(a: DuelAssertions) -> void:
	var sim := _sim()
	var player: PlayerState = sim.players[0]
	sim.weapons.config = sim.config
	player.inventory.weapons[0] = {"id": 1, "kind": 1, "magazine": 24, "next_shot_us": 0}
	player.inventory.active_slot = 0
	var frame := InputFrame.new()
	frame.actions = [{"kind": "fire"}]
	sim.weapons.next_id = 8193
	sim.weapons.fire(player, frame, 100)
	a.equal(player.inventory.active().magazine, 24, "generation cap rejects shot before ammunition consumption")
	a.equal(player.inventory.revision, 0, "rejected shot leaves inventory revision unchanged")
	player.action = CanonicalCodec.Action.GRENADE_AIM
	player.inventory.selected_grenade = 2
	player.inventory.grenades = [0, 1]
	sim.grenade.next_flame_id = 8193
	a.truth(not sim.grenade.throw_from(player, 100).ok, "no throw when flame generation cap reached")
	a.equal(player.inventory.grenades, [0, 1], "rejected throw preserves stock")
	sim.grenade.next_flame_id = 1
	for index in 7: sim.grenade.flames.append({"id": index + 1})
	a.truth(sim.grenade.has_generation_capacity(2), "one remaining flame slot")
	sim.grenade.grenades.append({"kind": 2})
	a.truth(not sim.grenade.has_generation_capacity(2), "in-flight incendiary reserves the last flame slot")
	a.truth(sim.grenade.has_generation_capacity(1), "flame cap does not prevent fragment grenade")
	var replica := EntityReplica.new()
	for id in range(1, 8193): replica._remember(1, id)
	a.truth(replica._remember(1, 8192), "duplicate does not consume cumulative allowance")
	a.truth(not replica._remember(1, 8193), "unbounded remote IDs rejected")
	a.equal(replica.known_ids.size(), 8192, "remote ID table remains bounded")
	replica.reset(2)
	a.truth(replica._remember(1, 1), "new round resets ID namespace")

func test_pellet_identity_and_correction_duplicates(a: DuelAssertions) -> void:
	var pellets: Array = []
	for index in 8:
		var projectile := _projectile()
		projectile.kind = 2
		projectile.id = index + 1
		projectile.pelletIndex = index
		pellets.append(projectile)
	var event := EntityWire.tagged(1, {"shotId": 1, "weaponId": 10, "owner": 0, "recoilPitch": 0.0, "recoilYaw": 0.0, "projectiles": pellets})
	var message := {"round": 1, "firstEventSeq": 1, "serverTick": 100, "events": [event]}
	a.truth(MessagePolicy.decoded(22, message).ok, "eight distinct shotgun pellets")
	event.payload.projectiles[7].pelletIndex = 6
	a.truth(not MessagePolicy.decoded(22, message).ok, "duplicated pellet index rejected")
	event.payload.projectiles[7].pelletIndex = 0
	event.payload.projectiles[7].kind = 1
	a.truth(not MessagePolicy.decoded(22, message).ok, "mixed weapon kinds in one shot rejected")
	var entity := {"kind": 1, "id": 1, "position": SnapshotCodec.vector(Vector3.ZERO), "velocity": SnapshotCodec.vector(Vector3.ZERO)}
	var correction := {"round": 1, "tick": 102, "requiredEventSeq": 1, "entities": [entity, entity.duplicate(true)]}
	a.truth(not MessagePolicy.decoded(12, correction).ok, "one correction per entity and tick")
	correction.entities[1].kind = 2
	a.truth(MessagePolicy.decoded(12, correction).ok, "separate entity namespaces allowed")

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

func test_delayed_baseline_preserves_newer_motion(a: DuelAssertions) -> void:
	var sim := _sim()
	sim.round_number = 1
	var baseline: Dictionary = EntityWire.baseline(sim, 100, 1, 0).value
	var replica := EntityReplica.new()
	replica.reset(1)
	var now := Time.get_ticks_msec()
	var shot := EntityWire.tagged(1, {"shotId": 1, "weaponId": 10, "owner": 0, "recoilPitch": 0.0, "recoilYaw": 0.0, "projectiles": [_projectile()]})
	replica.events({"round": 1, "firstEventSeq": 1, "serverTick": 101, "events": [shot]}, sim, now)
	replica.correction({"round": 1, "tick": 105, "requiredEventSeq": 1, "entities": [{"kind": 1, "id": 1, "position": SnapshotCodec.vector(Vector3(0, 0, -5)), "velocity": SnapshotCodec.vector(Vector3(0, 0, -100))}]}, sim, now)
	a.truth(replica.install(baseline, sim), "older baseline can replay known events")
	a.equal(sim.weapons.projectiles[0].position, Vector3(0, 0, -5), "newer correction survives baseline replay")
	a.equal(replica.notifications.size(), 1, "replayed shot does not repeat notification")
	var next: Dictionary = EntityWire.baseline(sim, 110, 2, 1).value
	replica.correction({"round": 1, "tick": 108, "requiredEventSeq": 3, "entities": [{"kind": 1, "id": 1, "position": SnapshotCodec.vector(Vector3(0, 0, -8)), "velocity": SnapshotCodec.vector(Vector3.ZERO)}]}, sim, now)
	a.truth(replica.install(next, sim), "newer baseline installed")
	a.equal(replica.corrections.size(), 0, "queued corrections older than baseline discarded")
	a.equal(sim.weapons.projectiles[0].position, Vector3(0, 0, -5), "obsolete queued correction cannot rewind state")

func test_incomplete_replay_does_not_modify_pending(a: DuelAssertions) -> void:
	var sim := _sim()
	sim.round_number = 1
	var baseline: Dictionary = EntityWire.baseline(sim, 100, 1, 0).value
	var replica := EntityReplica.new()
	replica.reset(1)
	replica.sequence = 2
	var event := EntityWire.tagged(2, {"id": 1, "reason": 1, "point": SnapshotCodec.vector(Vector3.ZERO), "normal": SnapshotCodec.vector(Vector3.UP)})
	replica.replay_events[1] = {"event": event, "size": 32}
	replica.replay_bytes = 32
	replica.pending[4] = {"event": event, "time": Time.get_ticks_msec(), "size": 32}
	replica.pending_bytes = 32
	var before := replica.pending.duplicate(true)
	a.truth(not replica.install(baseline, sim), "missing later replay event rejects baseline")
	a.equal(replica.pending, before, "failed replay preflight leaves queue unchanged")
	a.equal(replica.pending_bytes, 32, "failed baseline preserves queue accounting")
	a.equal(replica.sequence, 2, "failed baseline preserves applied sequence")
	a.equal(replica.baseline_id, 0, "failed baseline is not acknowledged")
	a.equal(replica.request_reason, 1, "missing replay requests a fresh baseline")
