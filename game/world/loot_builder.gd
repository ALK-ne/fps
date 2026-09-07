class_name LootBuilder
extends RefCounted

static func generate(config: GameConfig, seed_value: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var items: Array = []
	var a: Dictionary = config.arena
	var anchors: Array = []
	for sign_value in [-1, 1]:
		for z in a.spawnZ: anchors.append(Vector3(sign_value * 15, 0.35, z))
	for pos in a.weaponSlots.extra: anchors.append(ArenaBuilder.vec(pos) + Vector3.UP * 0.35)
	var id := 1
	for pos in anchors:
		var kind := weighted(rng, a.weaponSlots.weights) + 1
		items.append({"id": id, "revision": 0, "kind": 1, "subtype": kind, "amount": 1, "position": pos,
			"weapon": {"id": id, "kind": kind, "magazine": int(config.weapon(kind).magazine), "next_shot_us": 0}})
		id += 1
		if rng.randf() < a.weaponSlots.ammoChance:
			items.append({"id": id, "revision": 0, "kind": 2, "subtype": kind, "amount": int(config.weapon(kind).ammoBox), "position": pos + Vector3(0, 0, 0.7)})
		id += 1
	for group in [[a.healSlots, a.healChance, a.healWeights, 3], [a.grenadeSlots, a.grenadeChance, a.grenadeWeights, 4]]:
		for pos in group[0]:
			if rng.randf() < group[1]:
				items.append({"id": id, "revision": 0, "kind": group[3], "subtype": weighted(rng, group[2]) + 1, "amount": 1, "position": ArenaBuilder.vec(pos) + Vector3.UP * 0.3})
			id += 1
	return items

static func weighted(rng: RandomNumberGenerator, weights: Array) -> int:
	var total := 0.0
	for weight in weights: total += float(weight)
	var value := rng.randf() * total
	for i in weights.size():
		value -= float(weights[i])
		if value < 0: return i
	return weights.size() - 1
