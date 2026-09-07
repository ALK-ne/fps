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
	for slot in [priority, 1 - priority]:
		var player: PlayerState = players[slot]
		var frame: InputFrame = frames[slot]
		if player.hp_milli <= 0: continue
		if player.movement.vaulting:
			if player.action == CanonicalCodec.Action.SWAP: player.action = CanonicalCodec.Action.IDLE
			continue
		var item := target(player)
		if player.action == CanonicalCodec.Action.SWAP:
			if not frame.held(InputFrame.INTERACT) or item.is_empty() or item.id != player.action_target or item.revision != player.action_revision:
				player.action = CanonicalCodec.Action.IDLE
			elif tick >= player.action_end_tick:
				var gun: Dictionary = player.inventory.active().duplicate(true)
				player.inventory.weapons[player.inventory.active_slot] = item.weapon.duplicate(true)
				player.inventory.revision += 1
				item.amount = 0
				item.revision += 1
				var pos := player.position + Vector3(-sin(player.yaw), 0, -cos(player.yaw)) * 0.7
				if not queries.ray(player.position + Vector3.UP * 0.3, pos + Vector3.UP * 0.3).is_empty(): pos = player.position
				items.append({"id": gun.id, "revision": 0, "kind": 1, "subtype": gun.kind, "amount": 1, "position": pos + Vector3.UP * 0.35, "weapon": gun})
				player.action = CanonicalCodec.Action.IDLE
				events.append({"kind": "pickup", "slot": slot})
		if player.action != CanonicalCodec.Action.IDLE or not frame.has_action("interact") or item.is_empty(): continue
		var result := player.inventory.add_pickup(item, config)
		if result.ok: events.append({"kind": "pickup", "slot": slot})
		elif result.error_code == "SWAP_REQUIRED":
			player.action = CanonicalCodec.Action.SWAP
			player.action_end_tick = tick + 60
			player.action_target = item.id
			player.action_revision = item.revision
	return events
