class_name Inventory
extends RefCounted

var revision: int = 0
var weapons: Array = [null, null]
var active_slot: int = -1
var reserve: Array = [0, 0, 0]
var heals: Array = [0, 0, 0, 0]
var grenades: Array = [0, 0]
var selected_heal: int = 1
var selected_grenade: int = 1

func active() -> Dictionary:
	return weapons[active_slot] if active_slot >= 0 and weapons[active_slot] != null else {}

func add_pickup(item: Dictionary, config: GameConfig) -> DuelResult:
	var kind: int = item.kind
	var sub: int = item.subtype - 1
	match kind:
		1:
			var slot := weapons.find(null)
			if slot < 0: return DuelResult.failure("SWAP_REQUIRED")
			weapons[slot] = item.weapon.duplicate(true)
			if active_slot < 0: active_slot = slot
			item.amount = 0
		2:
			var capacity: int = int(config.weapon(sub + 1).reserveCap) - int(reserve[sub])
			var count := mini(capacity, item.amount)
			if count <= 0: return DuelResult.failure("CAP_REACHED")
			reserve[sub] += count
			item.amount -= count
		3:
			if heals[sub] >= int(config.heal(sub + 1).cap): return DuelResult.failure("CAP_REACHED")
			heals[sub] += 1
			item.amount -= 1
		4:
			if grenades[0] + grenades[1] >= 2: return DuelResult.failure("CAP_REACHED")
			grenades[sub] += 1
			item.amount -= 1
		_: return DuelResult.failure("INVALID_PICKUP")
	revision += 1
	item.revision += 1
	return DuelResult.success()

func to_data() -> Dictionary:
	return {"revision": revision, "weapons": weapons.duplicate(true), "active_slot": active_slot, "reserve": reserve.duplicate(), "heals": heals.duplicate(), "grenades": grenades.duplicate(), "selected_heal": selected_heal, "selected_grenade": selected_grenade}

func apply_data(d: Dictionary) -> void:
	for key in to_data():
		if d.has(key): set(key, d[key])
