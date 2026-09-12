class_name EntityReplica
extends RefCounted

var round_number: int = 0
var sequence: int = 0
var baseline_id: int = 0
var baseline_tick: int = -1
var pending: Dictionary = {}
var history: Dictionary = {}
var tombstones: Dictionary = {}
var corrections: Array = []
var correction_ticks: Dictionary = {}
var request_reason: int = 0
var conflict: bool = false
var notifications: Array = []
var pending_bytes: int = 0
var spawn_hashes: Dictionary = {}
var sources: Dictionary = {}
var event_types: Dictionary = {}
var known_ids: Dictionary = {}
var generated_counts: Array = [0, 0, 0, 0, 0]

func reset(number: int) -> void:
	round_number = number
	sequence = 0
	baseline_id = 0
	baseline_tick = -1
	pending.clear()
	history.clear()
	tombstones.clear()
	corrections.clear()
	correction_ticks.clear()
	request_reason = 0
	conflict = false
	notifications.clear()
	pending_bytes = 0
	spawn_hashes.clear()
	sources.clear()
	event_types.clear()
	known_ids.clear()
	generated_counts = [0, 0, 0, 0, 0]

func events(data: Dictionary, sim: DuelSimulation, now: int) -> void:
	if data.round != round_number: return
	for index in data.events.size():
		var seq: int = data.firstEventSeq + index
		var event: Dictionary = data.events[index]
		if seq <= sequence:
			if history.has(seq) and history[seq] != event: conflict = true
			continue
		if pending.has(seq) and pending[seq].event != event:
			conflict = true
			return
		if pending.has(seq): continue
		var encoded := MessageCodec.encode(event.type, event.payload, true)
		if not encoded.ok: return
		var size: int = encoded.value.size()
		if pending.size() >= 1024 or pending_bytes + size > 262144:
			request_reason = 1
			return
		pending[seq] = {"event": event.duplicate(true), "time": now, "size": size}
		pending_bytes += size
	_drain(sim)
	maintain(sim, now)

func _drain(sim: DuelSimulation) -> void:
	while pending.has(sequence + 1):
		sequence += 1
		var event: Dictionary = pending[sequence].event
		pending_bytes -= int(pending[sequence].get("size", 0))
		pending.erase(sequence)
		var previous_notifications := notifications.size()
		if not history.has(sequence): event_types[event.type] = int(event_types.get(event.type, 0)) + 1
		_apply(event, sim)
		if history.has(sequence): notifications.resize(previous_notifications)
		history[sequence] = event
		if history.size() > 2048: history.erase(history.keys()[0])

func _list(sim: DuelSimulation, kind: int) -> Array:
	return sim.weapons.projectiles if kind == 1 else (sim.grenade.grenades if kind == 2 else (sim.grenade.flames if kind == 3 else sim.pickup.items))

func _key(kind: int, id: int) -> String:
	return "%d:%d" % [kind, id]

func _remember(kind: int, id: int) -> bool:
	var key := _key(kind, id)
	if known_ids.has(key): return true
	if generated_counts[kind] >= 8192:
		conflict = true
		return false
	known_ids[key] = true
	generated_counts[kind] += 1
	return true

func _spawn(sim: DuelSimulation, kind: int, data: Dictionary) -> void:
	if not _remember(kind, data.id): return
	var key := _key(kind, data.id)
	if tombstones.has(key): return
	var list := _list(sim, kind)
	var signature := DuelIds.digest(CanonicalCodec.encode(data))
	for item in list:
		if item.id == data.id:
			if spawn_hashes.get(key) != signature: request_reason = 2
			return
	if list.size() >= [0, 128, 4, 8, 32][kind]:
		request_reason = 2
		return
	list.append(EntityWire.model(data))
	spawn_hashes[key] = signature
	if kind <= 3: sources[_key(kind, data.shotId if kind == 1 else data.id)] = data.owner

func _remove(sim: DuelSimulation, kind: int, id: int) -> void:
	if not _remember(kind, id): return
	tombstones[_key(kind, id)] = sequence
	var list := _list(sim, kind)
	for i in range(list.size() - 1, -1, -1):
		if list[i].id == id: list.remove_at(i)

func _apply(event: Dictionary, sim: DuelSimulation) -> void:
	var p: Dictionary = event.payload
	match int(event.type):
		1:
			for projectile in p.projectiles: _spawn(sim, 1, projectile)
			notifications.append({"kind": "shot", "slot": p.owner, "weapon": p.projectiles[0].kind, "id": p.shotId, "position": SnapshotCodec.from_vector(p.projectiles[0].position)})
		2: _remove(sim, 1, p.id)
		3: notifications.append({"kind": "damage", "target": p.target, "amount": p.amountMilli, "head": p.hitKind == 1, "owner": sources.get(_key(1 if p.hitKind < 2 else p.hitKind, p.sourceId), -1)})
		4:
			if p.inventory.revision > sim.players[p.slot].inventory.revision: sim.players[p.slot].inventory.apply_data(SnapshotCodec.from_inventory(p.inventory))
		5:
			var found := false
			for item in sim.pickup.items:
				if item.id == p.id:
					found = true
					if p.revision > item.revision:
						item.merge(EntityWire.model(p), true)
			if p.amount == 0: _remove(sim, 4, p.id)
			elif not found: _spawn(sim, 4, p)
		6: _spawn(sim, 2, p)
		7: _spawn(sim, 3, p)
		8: notifications.append({"kind": "armor_break", "target": p.slot})
		9:
			if p.kind == 2 and p.reason == 1:
				for grenade in sim.grenade.grenades:
					if grenade.id == p.id: notifications.append({"kind": "explosion", "position": grenade.position})
			_remove(sim, p.kind, p.id)

func correction(data: Dictionary, sim: DuelSimulation, now: int) -> void:
	if data.round != round_number or data.tick <= baseline_tick: return
	for entity in data.entities:
		if tombstones.has(_key(entity.kind, entity.id)): continue
		if corrections.size() >= 128:
			request_reason = 2
			return
		corrections.append({"entity": entity, "tick": data.tick, "required": data.requiredEventSeq, "time": now})
	maintain(sim, now)

func maintain(sim: DuelSimulation, now: int) -> void:
	for entry in pending.values():
		if now - entry.time >= 500: request_reason = 1
	for entry in corrections.duplicate():
		var e: Dictionary = entry.entity
		var key := _key(e.kind, e.id)
		if tombstones.has(key) or entry.tick <= baseline_tick or entry.tick <= int(correction_ticks.get(key, -1)):
			corrections.erase(entry)
			continue
		if now - entry.time >= 1000:
			request_reason = 2
			corrections.erase(entry)
			continue
		if entry.required > sequence: continue
		for item in _list(sim, e.kind):
			if item.id == e.id:
				var delta: Vector3 = item.position - SnapshotCodec.from_vector(e.position)
				item.display_offset = delta if delta.length() < 1 else Vector3.ZERO
				item.display_remaining = 0.05
				item.position = SnapshotCodec.from_vector(e.position)
				item.velocity = SnapshotCodec.from_vector(e.velocity)
				correction_ticks[key] = entry.tick
				corrections.erase(entry)
				break

func visual_step(sim: DuelSimulation, tick: int) -> void:
	for kind in [1, 2]:
		for entity in _list(sim, kind):
			entity.hidden = tick >= entity.expiry_tick
			if entity.hidden: continue
			if kind == 1: entity.position += entity.velocity / 60.0
			else:
				entity.velocity.y -= 16.0 / 60.0
				var remaining := 1.0 / 60.0
				for bounce in 3:
					var to: Vector3 = entity.position + entity.velocity * remaining
					var hit := sim.queries.grenade_sweep(entity.position, to)
					if hit.is_empty():
						entity.position = to
						break
					entity.position = hit.position + hit.normal * 0.02
					if entity.kind == 2:
						entity.velocity = Vector3.ZERO
						break
					entity.velocity -= 1.45 * entity.velocity.dot(hit.normal) * hit.normal
					remaining *= 1 - float(hit.fraction)

func install(data: Dictionary, sim: DuelSimulation) -> bool:
	if data.round != round_number or data.baselineId <= baseline_id or data.tick < baseline_tick: return false
	var newer_motion: Dictionary = {}
	for kind in [1, 2]:
		for item in _list(sim, kind):
			var key := _key(kind, item.id)
			if int(correction_ticks.get(key, -1)) > data.tick:
				newer_motion[key] = {"position": item.position, "velocity": item.velocity}
	if data.cutEventSeq < sequence:
		for seq in range(data.cutEventSeq + 1, sequence + 1):
			if not history.has(seq):
				request_reason = 1
				return false
			pending[seq] = {"event": history[seq], "time": Time.get_ticks_msec()}
	var old_snapshot := [Replication.player_data(sim.players[0]), Replication.player_data(sim.players[1])]
	for pair in [["projectiles", 1], ["grenades", 2], ["flames", 3], ["pickups", 4]]:
		for entity in data[pair[0]]:
			if not _remember(pair[1], entity.id): return false
	Replication.apply_world(sim, EntityWire.world(data))
	# Inventory may already include a newer reliable event or snapshot.
	for slot in 2:
		if old_snapshot[slot].inventory.revision > sim.players[slot].inventory.revision: sim.players[slot].inventory.apply_data(old_snapshot[slot].inventory)
	baseline_id = data.baselineId
	baseline_tick = data.tick
	sequence = data.cutEventSeq
	for key in tombstones.keys():
		if tombstones[key] > sequence: tombstones.erase(key)
	for seq in pending.keys():
		if seq <= sequence:
			pending_bytes -= int(pending[seq].get("size", 0))
			pending.erase(seq)
	request_reason = 0
	_drain(sim)
	# A reliable baseline can arrive after a newer unreliable correction.
	# Preserve its advanced visual motion only for entities surviving the cut replay.
	for kind in [1, 2]:
		for item in _list(sim, kind):
			var key := _key(kind, item.id)
			if newer_motion.has(key): item.merge(newer_motion[key], true)
	maintain(sim, Time.get_ticks_msec())
	return true
