class_name EventJournal
extends RefCounted

var round_number: int = 0
var sequence: int = 0
var revisions: Array = [-1, -1]
var pickups: Dictionary = {}
var event_types: Dictionary = {}

static func batches(events: Array) -> DuelResult:
	var result: Array = []
	var batch: Array = []
	var bytes := 22 # round, firstEventSeq, serverTick, count
	for event in events:
		var encoded := MessageCodec.encode(event.type, event.payload, true)
		if not encoded.ok: return encoded
		var size: int = encoded.value.size() + 3 # type and payload length
		if size + 22 > 32768: return DuelResult.failure("PAYLOAD_LIMIT")
		if batch.size() >= 64 or bytes + size > 32768:
			result.append(batch)
			batch = []
			bytes = 22
		batch.append(event)
		bytes += size
	if not batch.is_empty(): result.append(batch)
	return DuelResult.success(result)

func reset(number: int) -> void:
	round_number = number
	sequence = 0
	revisions = [-1, -1]
	pickups.clear()
	event_types.clear()

func observe(sim: DuelSimulation) -> void:
	for player in sim.players: revisions[player.slot] = player.inventory.revision
	pickups.clear()
	for item in sim.pickup.items:
		if item.amount > 0: pickups[item.id] = item.revision

func collect(sim: DuelSimulation, events: Array) -> Array:
	if round_number != sim.round_number: reset(sim.round_number)
	var result: Array = []
	var ordered: Array = []
	for e in events:
		if e.kind in ["shot", "throw"]: ordered.append(e)
	for e in events:
		if e.kind not in ["shot", "throw"]: ordered.append(e)
	for e in ordered:
		match e.kind:
			"shot":
				var spawned: Array = []
				for p in e.projectiles: spawned.append(EntityWire.projectile(p))
				result.append(EntityWire.tagged(1, {"shotId": e.id, "weaponId": e.weapon_id, "owner": e.slot, "recoilPitch": e.recoil.x, "recoilYaw": e.recoil.y, "projectiles": spawned}))
			"projectile_ended": result.append(EntityWire.tagged(2, {"id": e.id, "reason": e.reason, "point": SnapshotCodec.vector(e.point), "normal": SnapshotCodec.vector(e.normal)}))
			"damage": result.append(EntityWire.tagged(3, {"target": e.target, "amountMilli": e.amount, "hitKind": e.get("hit_kind", 1 if e.head else 0), "sourceId": e.shot_id}))
			"throw": result.append(EntityWire.tagged(6, EntityWire.grenade(e.grenade)))
			"flame_created": result.append(EntityWire.tagged(7, EntityWire.flame(e.flame)))
			"armor_break": result.append(EntityWire.tagged(8, {"slot": e.target}))
			"entity_removed": result.append(EntityWire.tagged(9, {"kind": e.entity_kind, "id": e.id, "reason": e.reason}))
	for player in sim.players:
		if player.inventory.revision != revisions[player.slot]:
			result.append(EntityWire.tagged(4, {"slot": player.slot, "inventory": SnapshotCodec.inventory(player.inventory.to_data())}))
	for item in sim.pickup.items:
		if (item.amount > 0 and not pickups.has(item.id)) or (pickups.has(item.id) and pickups[item.id] != item.revision): result.append(EntityWire.tagged(5, EntityWire.pickup(item)))
	observe(sim)
	for event in result: event_types[event.type] = int(event_types.get(event.type, 0)) + 1
	return result
