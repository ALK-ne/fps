class_name MessagePolicy
extends RefCounted

# channel, sender (-1=both), legal receiving phases. Auth steps are checked separately.
const ALL := [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
const TABLE := {
	1: [0, 1, []], 2: [0, 0, []], 3: [0, 1, []], 4: [0, 0, []],
	5: [0, -1, ALL], 6: [0, -1, [0]], 10: [1, 1, [5]], 11: [2, 0, [4, 5]],
	12: [2, 0, [5]], 20: [3, 1, [5]], 21: [3, 0, ALL], 22: [3, 0, [1, 4, 5, 6]],
	23: [0, 0, ALL], 24: [3, 0, [1, 4, 5, 6]], 25: [3, 1, [1, 4, 5, 6]],
	26: [3, 1, [1, 4, 5, 6]], 30: [3, 0, ALL], 31: [3, -1, ALL],
	32: [0, -1, [7, 8, 9]], 33: [3, -1, [7]], 34: [3, -1, [7]],
	35: [3, 0, [7]], 36: [3, 1, [7]], 37: [3, 0, [1, 6, 7]], 39: [3, 0, [1, 6, 7]],
	40: [0, -1, [8, 9]], 41: [0, -1, ALL], 42: [0, 0, [8, 9]],
	43: [0, -1, [7, 8, 9, 10]], 44: [0, -1, [7, 8, 9, 10]], 45: [0, -1, [7, 8, 9, 10]],
	50: [0, 1, [2, 3]]
}

static func envelope(kind: int, channel: int, sender_slot: int, authenticated: bool, phase: int, expected_handshake: int = 0) -> DuelResult:
	if not TABLE.has(kind): return DuelResult.failure("UNKNOWN_TYPE")
	var rule: Array = TABLE[kind]
	if channel != rule[0] or sender_slot not in [0, 1] or (rule[1] != -1 and sender_slot != rule[1]): return DuelResult.failure("WRONG_DIRECTION")
	if kind <= 4:
		return DuelResult.success() if not authenticated and kind == expected_handshake else DuelResult.failure("WRONG_AUTH_STAGE")
	if not authenticated: return DuelResult.failure("NOT_AUTHENTICATED")
	if phase == 10 and kind == 41: return DuelResult.success()
	if phase not in rule[2]: return DuelResult.failure("WRONG_PHASE")
	return DuelResult.success()

static func receive(kind: int, bytes: PackedByteArray, channel: int, sender_slot: int, authenticated: bool, phase: int, expected_handshake: int = 0) -> DuelResult:
	var gate := envelope(kind, channel, sender_slot, authenticated, phase, expected_handshake)
	if not gate.ok: return gate
	var payload := MessageCodec.decode(kind, bytes)
	if not payload.ok: return payload
	var semantic := decoded(kind, payload.value)
	return payload if semantic.ok else semantic

# Structural validation always precedes this entry point; opaque durable blobs
# additionally require RecoveryStore schema/hash/reducer validation before mutation.
static func decoded(kind: int, data: Dictionary) -> DuelResult:
	var error := _tree(data)
	if not error.is_empty(): return DuelResult.failure(error)
	match kind:
		10:
			var previous := 0
			for sample in data.samples:
				if sample.seq <= previous or sample.sampleTick < 0 or sample.axisX == -32768 or sample.axisY == -32768 or sample.held & ~63: return DuelResult.failure("INVALID_INPUT")
				previous = sample.seq
		20:
			if data.actionId <= 0 or data.inputSeq <= 0 or data.sampleTick < 0: return DuelResult.failure("INVALID_INPUT")
			if data.actionType != 5 and (data.targetId != 0 or data.expectedRevision != 0): return DuelResult.failure("INVALID_INPUT")
			match data.actionType:
				1:
					if data.argument not in [0, 1]: return DuelResult.failure("INVALID_INPUT")
				3, 9:
					if data.argument not in [1, 2, 3, 4]: return DuelResult.failure("INVALID_INPUT")
				10:
					if data.argument not in [1, 2]: return DuelResult.failure("INVALID_INPUT")
				_:
					if data.argument != 0: return DuelResult.failure("INVALID_INPUT")
		12:
			var ids: Dictionary = {}
			for entity in data.entities:
				var key := "%d:%d" % [entity.kind, entity.id]
				if entity.id < 1 or ids.has(key): return DuelResult.failure("INVALID_ENTITY")
				ids[key] = true
		11, 24:
			if data.player0.slot != 0 or data.player1.slot != 1: return DuelResult.failure("INVALID_SLOT")
			for player in [data.player0, data.player1]:
				if player.hp < 0 or player.hp > 100000 or player.armor < 0 or player.armor > player.armorMax or player.armorMax != MatchReducer.armor_for_round(data.round) * 1000 or player.flags & ~15: return DuelResult.failure("INVALID_PLAYER")
			if kind == 24:
				for pair in [["projectiles", 1], ["grenades", 2], ["flames", 3], ["pickups", 4]]:
					var ids: Dictionary = {}
					for entity in data[pair[0]]:
						if ids.has(entity.id) or not _entity(pair[1], entity): return DuelResult.failure("INVALID_ENTITY")
						ids[entity.id] = true
		22:
			if data.firstEventSeq < 1: return DuelResult.failure("INVALID_EVENT_SEQ")
			for event in data.events:
				var p: Dictionary = event.payload
				match int(event.type):
					1:
						var ids: Dictionary = {}
						var pellets: Dictionary = {}
						for projectile in p.projectiles:
							if not _entity(1, projectile) or projectile.owner != p.owner or projectile.shotId != p.shotId or projectile.kind != p.projectiles[0].kind or ids.has(projectile.id) or pellets.has(projectile.pelletIndex): return DuelResult.failure("INVALID_ENTITY")
							ids[projectile.id] = true
							pellets[projectile.pelletIndex] = true
						if p.projectiles.size() != (8 if p.projectiles[0].kind == 2 else 1): return DuelResult.failure("INVALID_ENTITY")
					3:
						if p.amountMilli <= 0: return DuelResult.failure("INVALID_DAMAGE")
					5, 6, 7:
						if not _entity({5: 4, 6: 2, 7: 3}[int(event.type)], p): return DuelResult.failure("INVALID_ENTITY")
		31:
			if data.ackKind == 0:
				for byte in data.checkpointHash:
					if byte != 0: return DuelResult.failure("INVALID_ACK")
		32:
			if data.continuous == 0:
				if data.remainingMs != 0xffffffff: return DuelResult.failure("INVALID_DEADLINE")
			elif data.remainingMs > 60000: return DuelResult.failure("INVALID_DEADLINE")
		35, 36:
			if data.remainingMs > 60000: return DuelResult.failure("INVALID_DEADLINE")
		34:
			if (data.done == 1 and not data.record.is_empty()) or (data.done == 0 and data.record.size() < 128): return DuelResult.failure("INVALID_HISTORY")
	return DuelResult.success()

static func _entity(kind: int, p: Dictionary) -> bool:
	if p.id < 1: return false
	if kind <= 3:
		if p.expiryTick <= p.spawnTick or p.expiryTick - p.spawnTick != [0, 120, 150, 300][kind]: return false
		if kind == 1 and (p.shotId < 1 or p.pelletIndex > (7 if p.kind == 2 else 0)): return false
		if kind == 3 and (p.nextDamageTick <= p.spawnTick or p.nextDamageTick > p.expiryTick): return false
	else:
		if p.subtype < 1 or p.subtype > [0, 3, 3, 4, 2][p.kind]: return false
		if p.kind == 1:
			if p.amount > 1 or p.weapon.id < 1 or p.weapon.kind != p.subtype or p.weapon.magazine > [0, 24, 6, 12][p.subtype]: return false
		elif p.weapon.kind != 0 or p.weapon.id != 0 or p.weapon.magazine != 0: return false
		if p.kind == 2 and p.amount > [0, 120, 30, 60][p.subtype]: return false
		if p.kind == 3 and p.amount > [0, 4, 2, 4, 2][p.subtype]: return false
		if p.kind == 4 and p.amount > 2: return false
	return true

static func _tree(value: Variant, field: String = "") -> String:
	if value is int and value < 0 and field not in ["axisX", "axisY", "argument", "activeSlot", "spawn0", "spawn1", "winner", "offender"]:
		return "INTEGER_RANGE"
	if value is Array:
		for item in value:
			var error := _tree(item, field)
			if not error.is_empty(): return error
	elif value is Dictionary:
		if value.has_all(["x", "y", "z"]) and value.size() == 3:
			var limit := 1024.0 if field == "velocity" else 4096.0
			for axis in ["x", "y", "z"]:
				if absf(value[axis]) > limit: return "VECTOR_RANGE"
		if field == "inventory":
			var error := _inventory(value)
			if not error.is_empty(): return error
		if value.has("evidence") and value.evidence & ~127: return "RESERVED_BITS"
		for key in value:
			if key == "yaw" and absf(value[key]) > PI + 0.000001: return "ANGLE_RANGE"
			if key == "pitch" and absf(value[key]) > PI / 2 + 0.000001: return "ANGLE_RANGE"
			var error := _tree(value[key], key)
			if not error.is_empty(): return error
	return ""

static func _inventory(inv: Dictionary) -> String:
	var caps := {"reserveRifle": 120, "reserveShotgun": 30, "reservePistol": 60, "healthSmall": 4, "healthFull": 2, "armorSmall": 4, "armorFull": 2}
	for key in caps:
		if inv[key] > caps[key]: return "INVENTORY_CAP"
	if inv.frag + inv.incendiary > 2: return "INVENTORY_CAP"
	var guns: Array = [inv.weapon0, inv.weapon1]
	for gun in guns:
		if gun.kind == 0:
			if gun.id != 0 or gun.magazine != 0: return "INVALID_WEAPON"
		elif gun.id == 0 or gun.magazine > [0, 24, 6, 12][gun.kind]: return "INVALID_WEAPON"
	if guns[0].id != 0 and guns[0].id == guns[1].id: return "DUPLICATE_WEAPON"
	if inv.activeSlot >= 0 and guns[inv.activeSlot].kind == 0: return "INVALID_ACTIVE_SLOT"
	return ""
