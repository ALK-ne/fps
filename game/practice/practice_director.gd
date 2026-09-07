class_name PracticeDirector
extends RefCounted

var world: WorldView
var seed_value: int = 20260906
var moving: bool = false
var respawn_tick: int = 0
var first_hit_tick: int = -1
var last_ttk_ms: int = 0
var hits: int = 0
var head_hits: int = 0
var target_origin := Vector3(0, 0.05, -6)

func reset(reroll: bool = false) -> void:
	if reroll: seed_value = int(DuelIds.random_bytes(4).decode_u32(0))
	world.simulation.reset_round(1, [0, 3], seed_value)
	world.simulation.players[1].position = target_origin
	world.simulation.queries.proxies[1].position = target_origin
	world.sync_items()
	respawn_tick = 0
	first_hit_tick = -1

func step(frame: InputFrame, tick: int) -> Array:
	var sim := world.simulation
	var other := InputFrame.new()
	other.yaw = PI
	var target := sim.players[1]
	if respawn_tick > 0 and tick >= respawn_tick:
		target.reset(1)
		target.position = target_origin
		respawn_tick = 0
		first_hit_tick = -1
	if target.hp_milli > 0:
		target.position = target_origin + Vector3(sin(tick / 60.0) * 3 if moving else 0.0, 0, 0)
		target.velocity = Vector3.ZERO
	var events := sim.step([frame, other], tick)
	for event in events:
		if event.kind == "damage" and event.target == 1:
			hits += 1
			if event.get("head", false): head_hits += 1
			if first_hit_tick < 0: first_hit_tick = tick
	if target.hp_milli <= 0 and respawn_tick == 0:
		last_ttk_ms = (tick - first_hit_tick) * 1000 / 60
		respawn_tick = tick + 120
	return events
