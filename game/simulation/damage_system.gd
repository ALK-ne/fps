class_name DamageSystem
extends RefCounted

static func apply(players: Array, events: Array) -> Array:
	var totals: Dictionary = {}
	var results: Array = []
	for e in events:
		if e.target < 0 or e.target >= players.size() or e.amount <= 0: continue
		totals[e.target] = int(totals.get(e.target, 0)) + int(e.amount)
		results.append(e)
	for slot in totals:
		var player: PlayerState = players[slot]
		var absorbed := mini(player.armor_milli, int(totals[slot]))
		player.armor_milli -= absorbed
		player.hp_milli = maxi(0, player.hp_milli - (int(totals[slot]) - absorbed))
		if absorbed > 0 and player.armor_milli == 0: results.append({"kind": "armor_break", "target": slot})
	return results
