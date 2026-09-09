class_name StoreSchema
extends RefCounted

const KEYS := {
	1: ["players", "map_hash", "initial_epoch"],
	2: ["round", "first_slot"],
	3: ["round"],
	4: ["round", "winner", "reason", "closed_tick"],
	5: ["recovery_id", "old_epoch", "new_epoch", "interrupted_round", "disposition", "offender", "base_seq", "base_hash"],
	6: ["covered_seq", "covered_hash", "state_hash"]
}

static func exact(d: Dictionary, keys: Array) -> bool:
	return d.size() == keys.size() and d.has_all(keys)

static func bytes(value: Variant, length: int) -> bool:
	return value is PackedByteArray and value.size() == length

static func integer(value: Variant, low: int = 0, high: int = 0x7fffffffffffffff) -> bool:
	return value is int and value >= low and value <= high

static func validate(kind: int, p: Dictionary) -> bool:
	if not KEYS.has(kind) or not exact(p, KEYS[kind]): return false
	match kind:
		1:
			if not p.players is Array or p.players.size() != 2: return false
			return bytes(p.players[0], 16) and bytes(p.players[1], 16) and p.players[0] != p.players[1] and bytes(p.map_hash, 32) and integer(p.initial_epoch, 1, 0xffffffff)
		2: return integer(p.round, 1, 0xffffffff) and integer(p.first_slot, 0, 1)
		3: return integer(p.round, 1, 0xffffffff)
		4: return integer(p.round, 1, 0xffffffff) and integer(p.winner, -1, 1) and integer(p.reason, 0, 2) and integer(p.closed_tick)
		5: return bytes(p.recovery_id, 16) and integer(p.old_epoch, 1, 0xffffffff) and integer(p.new_epoch, p.old_epoch + 1, 0xffffffff) and integer(p.interrupted_round, 0, 0xffffffff) and integer(p.disposition, 0, 3) and integer(p.offender, -1, 1) and integer(p.base_seq) and bytes(p.base_hash, 32)
		6: return integer(p.covered_seq, 1) and bytes(p.covered_hash, 32) and bytes(p.state_hash, 32)
	return false

static func payload(event: MatchEvent, seq: int, previous: PackedByteArray) -> Dictionary:
	var p := event.payload
	match event.type:
		1: return {"players": [p.players[0].id, p.players[1].id], "map_hash": p.map_hash, "initial_epoch": p.epoch}
		2: return {"round": p.round, "first_slot": p.first_slot}
		3: return {"round": p.round}
		4: return {"round": p.round, "winner": p.winner, "reason": p.reason, "closed_tick": p.closed_tick}
		5: return {"recovery_id": str(p.recovery_id).hex_decode(), "old_epoch": p.old_epoch, "new_epoch": p.new_epoch, "interrupted_round": p.round, "disposition": p.disposition, "offender": p.offender, "base_seq": seq - 1, "base_hash": previous}
	return p

static func event(kind: int, p: Dictionary, mid: PackedByteArray, rules: PackedByteArray) -> MatchEvent:
	var d := p.duplicate(true)
	match kind:
		1:
			d = {"match_id": mid, "rule_hash": rules, "map_hash": p.map_hash, "players": [{"id": p.players[0], "slot": 0}, {"id": p.players[1], "slot": 1}], "epoch": p.initial_epoch}
		5:
			d.round = p.interrupted_round
			d.recovery_id = p.recovery_id.hex_encode()
	return MatchEvent.make(kind, d)

static func session_data(value: Dictionary, local_id: PackedByteArray) -> DuelResult:
	var keys := ["match", "rules", "map", "protocol", "storeSchema", "secret", "endpoint", "players", "old_boots", "epoch_highwater"]
	if not exact(value, keys): return DuelResult.failure("LEGACY_SCHEMA" if not value.has("storeSchema") else "STORE_CORRUPT")
	if not integer(value.protocol, 2, 2) or not integer(value.storeSchema, 2, 2): return DuelResult.failure("VERSION_MISMATCH")
	for field in ["rules", "map", "secret"]:
		if not bytes(value[field], 32): return DuelResult.failure("STORE_CORRUPT")
	if not bytes(value.match, 16) or not integer(value.epoch_highwater, 0, 0xffffffff): return DuelResult.failure("STORE_CORRUPT")
	for field in ["players", "old_boots"]:
		if not value[field] is Array or value[field].size() != 2: return DuelResult.failure("STORE_CORRUPT")
		for id in value[field]:
			if not bytes(id, 16): return DuelResult.failure("STORE_CORRUPT")
	if local_id not in value.players or value.players[0] == value.players[1]: return DuelResult.failure("STORE_CORRUPT")
	if not value.endpoint is Dictionary or not exact(value.endpoint, ["host", "port"]) or not value.endpoint.host is String or value.endpoint.host.length() < 1 or value.endpoint.host.length() > 255 or not integer(value.endpoint.port, 1024, 65535): return DuelResult.failure("STORE_CORRUPT")
	var zero := PackedByteArray()
	zero.resize(16)
	var invitation := {"v": 2, "match": value.match.hex_encode(), "rules": value.rules.hex_encode(), "map": value.map.hex_encode(), "secret": value.secret.hex_encode(), "host": value.endpoint.host, "port": value.endpoint.port}
	return DuelResult.success({"invitation": invitation, "host": value.players[0] == local_id,
		"host_id": PackedByteArray() if value.players[0] == zero else value.players[0], "guest_id": PackedByteArray() if value.players[1] == zero else value.players[1],
		"host_boot": PackedByteArray() if value.old_boots[0] == zero else value.old_boots[0], "guest_boot": PackedByteArray() if value.old_boots[1] == zero else value.old_boots[1], "epoch": value.epoch_highwater})

static func session_value(data: Dictionary) -> Dictionary:
	var inv: Dictionary = data.invitation
	var zero := PackedByteArray()
	zero.resize(16)
	return {"match": inv.match.hex_decode(), "rules": inv.rules.hex_decode(), "map": inv.map.hex_decode(), "protocol": 2, "storeSchema": 2,
		"secret": inv.secret.hex_decode(), "endpoint": {"host": inv.host, "port": int(inv.port)},
		"players": [data.host_id if not data.host_id.is_empty() else zero, data.guest_id if not data.guest_id.is_empty() else zero],
		"old_boots": [data.host_boot if not data.host_boot.is_empty() else zero, data.guest_boot if not data.guest_boot.is_empty() else zero], "epoch_highwater": data.epoch}
