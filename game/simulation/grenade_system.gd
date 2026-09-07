class_name GrenadeSystem
extends RefCounted

var config: GameConfig
var queries: ArenaQueries
var grenades: Array = []
var flames: Array = []
var next_id: int = 1
var events: Array = []

func throw_from(player: PlayerState, tick: int) -> DuelResult:
	var kind := player.inventory.selected_grenade
	if player.action != CanonicalCodec.Action.GRENADE_AIM or player.inventory.grenades[kind - 1] < 1 or grenades.size() >= 4: return DuelResult.failure("ACTION_CONFLICT")
	var speed: float = config.rules.grenades.frag.speed if kind == 1 else config.rules.grenades.incendiary.speed
	var origin := player.eye() + player.direction() * 0.5
	if not queries.ray(player.eye(), origin).is_empty(): origin = player.eye()
	grenades.append({"id": next_id, "owner": player.slot, "kind": kind, "position": origin, "velocity": player.direction() * speed, "expiry_tick": tick + 150})
	next_id += 1
	player.inventory.grenades[kind - 1] -= 1
	player.inventory.revision += 1
	player.action = CanonicalCodec.Action.IDLE
	events.append({"kind": "throw", "slot": player.slot})
	return DuelResult.success()

func trajectory(player: PlayerState) -> Array[Vector3]:
	var points: Array[Vector3] = []
	var position := player.eye() + player.direction() * 0.5
	var velocity := player.direction() * (16.0 if player.inventory.selected_grenade == 1 else 14.0)
	points.append(position)
	for i in 50:
		velocity.y -= 16 * 0.05
		var to := position + velocity * 0.05
		var hit := queries.grenade_sweep(position, to)
		if not hit.is_empty():
			points.append(hit.position)
			break
		position = to
		points.append(position)
	return points

func step(players: Array, tick: int) -> Array:
	var damage: Array = []
	for i in range(grenades.size() - 1, -1, -1):
		var grenade: Dictionary = grenades[i]
		grenade.velocity.y -= 16.0 / 60.0
		var remaining := 1.0 / 60.0
		var ignited := false
		for bounce in 3:
			var to: Vector3 = grenade.position + grenade.velocity * remaining
			var hit := queries.grenade_sweep(grenade.position, to)
			if hit.is_empty():
				grenade.position = to
				break
			grenade.position = hit.position + hit.normal * 0.02
			if grenade.kind == 2:
				_ignite(grenade, tick)
				ignited = true
				break
			grenade.velocity -= 1.45 * grenade.velocity.dot(hit.normal) * hit.normal
			remaining *= 1 - float(hit.fraction)
		if ignited:
			grenades.remove_at(i)
		elif tick >= grenade.expiry_tick:
			if grenade.kind == 1:
				for player: PlayerState in players:
					var center := Vector3(player.position.x, clampf(grenade.position.y, player.position.y + 0.35, player.position.y + 1.45), player.position.z)
					var distance := maxf(0, center.distance_to(grenade.position) - 0.35)
					if distance < 4 and queries.explosion_visible(grenade.position, player):
						damage.append({"kind": "damage", "target": player.slot, "owner": grenade.owner, "amount": int(round(100000 * (1 - distance / 4) * (0.5 if player.slot == grenade.owner else 1.0))), "head": false, "shot_id": grenade.id})
				events.append({"kind": "explosion", "position": grenade.position})
			grenades.remove_at(i)
	for i in range(flames.size() - 1, -1, -1):
		var flame: Dictionary = flames[i]
		if tick >= flame.next_damage_tick and tick <= flame.expiry_tick:
			flame.next_damage_tick += 15
			for player: PlayerState in players:
				for cell: Vector3 in flame.cells:
					if absf(player.position.y - cell.y) < 0.4 and Vector2(player.position.x - cell.x, player.position.z - cell.z).length() <= 0.6:
						damage.append({"kind": "damage", "target": player.slot, "owner": flame.owner, "amount": 4000 if player.slot == flame.owner else 8000, "head": false, "shot_id": flame.id})
						break
		if tick >= flame.expiry_tick: flames.remove_at(i)
	return damage

func _ignite(grenade: Dictionary, tick: int) -> void:
	if flames.size() >= 8: return
	var floor_hit := queries.ray(grenade.position + Vector3.UP * 0.05, grenade.position + Vector3.DOWN * 5)
	if floor_hit.is_empty() or floor_hit.normal.y < 0.7: return
	var origin: Vector3 = floor_hit.position
	var queue: Array[Vector3] = [Vector3(round(origin.x * 2) / 2, origin.y, round(origin.z * 2) / 2)]
	var visited: Dictionary = {}
	var cells: Array[Vector3] = []
	while not queue.is_empty() and cells.size() < 81:
		var cell: Vector3 = queue.pop_front()
		var key := Vector2(cell.x, cell.z)
		if visited.has(key): continue
		visited[key] = true
		if Vector2(cell.x - origin.x, cell.z - origin.z).length() > 2.5: continue
		var hit := queries.ray(cell + Vector3.UP * 0.3, cell - Vector3.UP * 0.3)
		if hit.is_empty() or hit.normal.y < 0.7 or absf(hit.position.y - cell.y) > 0.3: continue
		cell.y = hit.position.y + 0.02
		cells.append(cell)
		for dir in [Vector3(0.5, 0, 0), Vector3(-0.5, 0, 0), Vector3(0, 0, 0.5), Vector3(0, 0, -0.5)]:
			if queries.ray(cell + Vector3.UP * 0.1, cell + dir + Vector3.UP * 0.1).is_empty(): queue.append(cell + dir)
	flames.append({"id": grenade.id, "owner": grenade.owner, "cells": cells, "expiry_tick": tick + 300, "next_damage_tick": tick + 15})
