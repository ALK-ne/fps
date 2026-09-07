class_name PickupSystem
extends RefCounted

var config: GameConfig
var queries: ArenaQueries
var items: Array = []

func target(player: PlayerState) -> Dictionary:
	var hit := queries.pickup_target(player)
	if hit.is_empty() or not hit.collider.has_meta("item_id"): return {}
	var id: int = hit.collider.get_meta("item_id")
	for item in items:
		if item.id == id and item.amount > 0: return item
	return {}

func step(players: Array, frames: Array, tick: int, round_number: int) -> Array:
	var events: Array = []
	var priority := (round_number - 1) % 2
	# Resolve both requests against the same pre-transaction revision.
	var targets: Array = [target(players[0]), target(players[1])]
	var revisions: Array = [targets[0].get("revision", -1), targets[1].get("revision", -1)]
	for slot in [priority, 1 - priority]:
		var player: PlayerState = players[slot]
		var frame: InputFrame = frames[slot]
		if not frame.held(InputFrame.INTERACT): player.interact_latched = false
		var pressed := frame.has_action("interact") and not player.interact_latched
		if pressed: player.interact_latched = true
		if player.hp_milli <= 0: continue
		if player.movement.vaulting:
			if player.action == CanonicalCodec.Action.SWAP: player.action = CanonicalCodec.Action.IDLE
			continue
		var item: Dictionary = targets[slot]
		if not item.is_empty() and (item.revision != revisions[slot] or item.amount <= 0):
			if pressed or player.action == CanonicalCodec.Action.SWAP:
				events.append({"kind": "action_rejected", "slot": slot, "reason": "STALE_ITEM"})
			if player.action == CanonicalCodec.Action.SWAP: player.action = CanonicalCodec.Action.IDLE
			continue
		if player.action == CanonicalCodec.Action.SWAP:
			if not frame.held(InputFrame.INTERACT) or item.is_empty() or item.id != player.action_target or item.revision != player.action_revision:
				player.action = CanonicalCodec.Action.IDLE
			elif tick >= player.action_end_tick:
				var gun: Dictionary = player.inventory.active().duplicate(true)
				player.inventory.weapons[player.inventory.active_slot] = item.weapon.duplicate(true)
				player.inventory.revision += 1
				item.amount = 0
				item.revision += 1
				items.append({"id": gun.id, "revision": 0, "kind": 1, "subtype": gun.kind, "amount": 1, "position": queries.weapon_drop_position(player), "weapon": gun})
				player.action = CanonicalCodec.Action.IDLE
				events.append({"kind": "pickup", "slot": slot})
			continue
		if player.action != CanonicalCodec.Action.IDLE or not pressed or item.is_empty(): continue
		var result := player.inventory.add_pickup(item, config)
		if result.ok: events.append({"kind": "pickup", "slot": slot})
		elif result.error_code == "SWAP_REQUIRED":
			player.action = CanonicalCodec.Action.SWAP
			player.action_end_tick = tick + 60
			player.action_target = item.id
			player.action_revision = item.revision
	return events
