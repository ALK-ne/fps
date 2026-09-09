class_name EntityWire
extends RefCounted

static func projectile(p: Dictionary) -> Dictionary:
	return {"id": p.id, "owner": p.owner, "kind": p.kind, "position": SnapshotCodec.vector(p.position), "velocity": SnapshotCodec.vector(p.velocity), "spawnTick": p.spawn_tick, "expiryTick": p.expiry_tick, "shotId": p.shot_id, "pelletIndex": p.pellet_index}

static func grenade(p: Dictionary) -> Dictionary:
	return {"id": p.id, "owner": p.owner, "kind": p.kind, "position": SnapshotCodec.vector(p.position), "velocity": SnapshotCodec.vector(p.velocity), "spawnTick": p.spawn_tick, "expiryTick": p.expiry_tick}

static func flame(p: Dictionary) -> Dictionary:
	var cells: Array = []
	for cell in p.cells: cells.append(SnapshotCodec.vector(cell))
	return {"id": p.id, "owner": p.owner, "spawnTick": p.spawn_tick, "expiryTick": p.expiry_tick, "nextDamageTick": p.next_damage_tick, "cells": cells}

static func pickup(p: Dictionary) -> Dictionary:
	return {"id": p.id, "revision": p.revision, "kind": p.kind, "subtype": p.subtype, "amount": p.amount, "position": SnapshotCodec.vector(p.position), "weapon": SnapshotCodec.weapon(p.get("weapon"))}

static func model(p: Dictionary) -> Dictionary:
	var d := p.duplicate(true)
	for key in ["position", "velocity"]:
		if d.has(key): d[key] = SnapshotCodec.from_vector(d[key])
	for pair in [["spawnTick", "spawn_tick"], ["expiryTick", "expiry_tick"], ["shotId", "shot_id"], ["pelletIndex", "pellet_index"], ["nextDamageTick", "next_damage_tick"]]:
		if d.has(pair[0]):
			d[pair[1]] = d[pair[0]]
			d.erase(pair[0])
	if d.has("cells"):
		var cells: Array[Vector3] = []
		for cell in d.cells: cells.append(SnapshotCodec.from_vector(cell))
		d.cells = cells
	if d.has("weapon"):
		if d.weapon.kind == 0: d.erase("weapon")
		else: d.weapon.next_shot_us = 0
	return d

static func baseline(sim: DuelSimulation, tick: int, id: int, cut: int) -> DuelResult:
	var d := {"round": sim.round_number, "baselineId": id, "tick": tick, "cutEventSeq": cut,
		"player0": SnapshotCodec.to_wire_player(Replication.player_data(sim.players[0])), "player1": SnapshotCodec.to_wire_player(Replication.player_data(sim.players[1])),
		"pickups": [], "projectiles": [], "grenades": [], "flames": [], "hash": PackedByteArray()}
	d.hash.resize(32)
	for p in sim.pickup.items:
		if p.amount > 0: d.pickups.append(pickup(p))
	for p in sim.weapons.projectiles: d.projectiles.append(projectile(p))
	for p in sim.grenade.grenades: d.grenades.append(grenade(p))
	for p in sim.grenade.flames: d.flames.append(flame(p))
	var encoded := MessageCodec.encode(24, d)
	if not encoded.ok: return encoded
	d.hash = DuelIds.digest(encoded.value.slice(0, encoded.value.size() - 32))
	return DuelResult.success(d)

static func world(d: Dictionary) -> Dictionary:
	var out := {"round": d.round, "tick": d.tick, "players": [SnapshotCodec.from_wire_player(d.player0), SnapshotCodec.from_wire_player(d.player1)], "items": [], "projectiles": [], "grenades": [], "flames": []}
	for pair in [["pickups", "items"], ["projectiles", "projectiles"], ["grenades", "grenades"], ["flames", "flames"]]:
		for p in d[pair[0]]: out[pair[1]].append(model(p))
	return out

static func tagged(kind: int, payload: Dictionary) -> Dictionary:
	return {"type": kind, "payload": payload}
