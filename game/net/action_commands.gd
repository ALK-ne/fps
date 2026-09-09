class_name ActionCommands
extends RefCounted

const KINDS := ["cancel", "switch", "grenade", "heal", "reload", "interact", "melee", "fire", "jump", "select_heal", "select_grenade", "throw"]

static func priority(request: Dictionary) -> int:
	return int(request.actionType) if request.actionType <= 7 else 8

static func preflight(request: Dictionary, player: PlayerState, simulation: DuelSimulation, tick: int) -> int:
	if player.hp_milli <= 0 or player.movement.vaulting: return 8
	var inv := player.inventory
	var gun := inv.active()
	var idle: bool = player.action == CanonicalCodec.Action.IDLE
	match int(request.actionType):
		0, 9, 10: return 0
		1: return 0 if inv.weapons[request.argument] != null else 11
		2:
			if player.action in [CanonicalCodec.Action.GRENADE_READY, CanonicalCodec.Action.GRENADE_AIM]: return 0
			return 0 if inv.grenades[inv.selected_grenade - 1] > 0 else 6
		3:
			if player.movement.sprinting or player.action in [CanonicalCodec.Action.GRENADE_READY, CanonicalCodec.Action.GRENADE_AIM]: return 8
			if inv.heals[request.argument - 1] == 0: return 6
			return 7 if (player.hp_milli == 100000 if request.argument <= 2 else player.armor_milli == player.armor_max) else 0
		4:
			if not idle: return 8
			if gun.is_empty() or inv.reserve[gun.kind - 1] == 0: return 6
			return 7 if gun.magazine >= simulation.config.weapon(gun.kind).magazine else 0
		5:
			if not idle or player.interact_latched: return 8
			var item := simulation.pickup.target(player)
			if item.is_empty() or item.id != request.targetId: return 11
			if item.revision != request.expectedRevision: return 3
			var copy := Inventory.new()
			copy.apply_data(inv.to_data())
			var result := copy.add_pickup(item.duplicate(true), simulation.config)
			return 0 if result.ok or result.error_code == "SWAP_REQUIRED" else 7
		6: return 10 if tick < player.next_melee_tick else (0 if idle else 8)
		7:
			if gun.is_empty() or gun.magazine == 0: return 6
			if simulation.weapons.projectiles.size() + int(simulation.config.weapon(gun.kind).pellets) > 128: return 8
			if not idle and player.action != CanonicalCodec.Action.RELOAD: return 8
			return 10 if tick * 1000000 / 60 < gun.next_shot_us else 0
		8: return 0 if player.movement.grounded else 8
		11:
			if player.action != CanonicalCodec.Action.GRENADE_AIM: return 8
			return 0 if inv.grenades[inv.selected_grenade - 1] > 0 else 6
	return 9

static func command(request: Dictionary) -> Dictionary:
	return {"kind": KINDS[request.actionType], "argument": request.argument, "target_id": request.targetId, "expected_revision": request.expectedRevision, "action_id": request.actionId}
