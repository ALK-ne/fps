class_name SnapshotCodec
extends RefCounted

# The 278-byte layout is shared with protocol 2. Translate model names at the
# boundary; all byte parsing and structural limits belong to MessageCodec.
static func encode(data: Dictionary) -> PackedByteArray:
	var result := MessageCodec.encode(11, {"round": data.round, "serverTick": data.tick, "player0": to_wire_player(data.players[0]), "player1": to_wire_player(data.players[1])})
	return result.value if result.ok else PackedByteArray()

static func decode(bytes: PackedByteArray) -> DuelResult:
	if bytes.size() != 278: return DuelResult.failure("INVALID_SNAPSHOT_SIZE", str(bytes.size()))
	var result := MessageCodec.decode(11, bytes)
	if not result.ok: return result
	var valid := MessagePolicy.decoded(11, result.value)
	if not valid.ok: return valid
	var data: Dictionary = result.value
	return DuelResult.success({"round": data.round, "tick": data.serverTick, "players": [from_wire_player(data.player0), from_wire_player(data.player1)]})

static func vector(value: Vector3) -> Dictionary:
	return {"x": value.x, "y": value.y, "z": value.z}

static func from_vector(value: Dictionary) -> Vector3:
	return Vector3(value.x, value.y, value.z)

static func weapon(gun: Variant) -> Dictionary:
	return {"id": 0, "kind": 0, "magazine": 0} if gun == null else {"id": gun.id, "kind": gun.kind, "magazine": gun.magazine}

static func inventory(inv: Dictionary) -> Dictionary:
	return {"revision": inv.revision, "activeSlot": inv.active_slot, "weapon0": weapon(inv.weapons[0]), "weapon1": weapon(inv.weapons[1]),
		"reserveRifle": inv.reserve[0], "reserveShotgun": inv.reserve[1], "reservePistol": inv.reserve[2],
		"healthSmall": inv.heals[0], "healthFull": inv.heals[1], "armorSmall": inv.heals[2], "armorFull": inv.heals[3],
		"frag": inv.grenades[0], "incendiary": inv.grenades[1], "selectedHeal": inv.selected_heal, "selectedGrenade": inv.selected_grenade}

static func from_inventory(inv: Dictionary) -> Dictionary:
	var guns: Array = []
	for gun in [inv.weapon0, inv.weapon1]:
		guns.append(null if gun.kind == 0 else {"id": gun.id, "kind": gun.kind, "magazine": gun.magazine, "next_shot_us": 0})
	return {"revision": inv.revision, "active_slot": inv.activeSlot, "weapons": guns,
		"reserve": [inv.reserveRifle, inv.reserveShotgun, inv.reservePistol], "heals": [inv.healthSmall, inv.healthFull, inv.armorSmall, inv.armorFull],
		"grenades": [inv.frag, inv.incendiary], "selected_heal": inv.selectedHeal, "selected_grenade": inv.selectedGrenade}

static func to_wire_player(p: Dictionary) -> Dictionary:
	return {"slot": p.slot, "position": vector(p.position), "velocity": vector(p.velocity), "yaw": wrapf(p.yaw, -PI, PI), "pitch": p.pitch,
		"hp": p.hp, "armor": p.armor, "armorMax": p.armor_max, "flags": (1 if p.grounded else 0) | (2 if p.crouched else 0) | (4 if p.sprinting else 0) | (8 if p.vaulting else 0),
		"action": p.action, "actionEndTick": p.action_end, "actionKind": p.action_kind, "ackInputSeq": p.ack, "slideRemaining": p.slide,
		"vaultStart": vector(p.vault_start), "vaultEnd": vector(p.vault_end), "vaultProgress": p.vault_progress,
		"recoilPitch": p.recoil[0], "recoilYaw": p.recoil[1], "inventory": inventory(p.inventory)}

static func from_wire_player(p: Dictionary) -> Dictionary:
	return {"slot": p.slot, "position": from_vector(p.position), "velocity": from_vector(p.velocity), "yaw": p.yaw, "pitch": p.pitch,
		"hp": p.hp, "armor": p.armor, "armor_max": p.armorMax, "grounded": bool(p.flags & 1), "crouched": bool(p.flags & 2), "sprinting": bool(p.flags & 4), "vaulting": bool(p.flags & 8),
		"action": p.action, "action_end": p.actionEndTick, "action_kind": p.actionKind, "ack": p.ackInputSeq, "slide": p.slideRemaining,
		"vault_start": from_vector(p.vaultStart), "vault_end": from_vector(p.vaultEnd), "vault_progress": p.vaultProgress,
		"recoil": [p.recoilPitch, p.recoilYaw], "inventory": from_inventory(p.inventory)}
