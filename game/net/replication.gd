class_name Replication
extends RefCounted

static func player_data(player: PlayerState) -> Dictionary:
	var m := player.movement
	return {"slot": player.slot, "position": player.position, "velocity": player.velocity, "yaw": player.yaw, "pitch": player.pitch,
		"hp": player.hp_milli, "armor": player.armor_milli, "armor_max": player.armor_max, "inventory": player.inventory.to_data(),
		"action": player.action, "action_end": player.action_end_tick, "action_kind": player.action_kind, "ack": player.last_input_seq,
		"grounded": m.grounded, "crouched": m.crouched, "sprinting": m.sprinting, "slide": m.slide_remaining_ticks,
		"vault_start": m.vault_start, "vault_end": m.vault_end, "vault_progress": m.vault_progress_ticks, "vaulting": m.vaulting, "recoil": [player.recoil.x, player.recoil.y]}

static func apply_player(player: PlayerState, d: Dictionary) -> void:
	player.position = d.position
	player.velocity = d.velocity
	player.yaw = d.yaw
	player.pitch = d.pitch
	player.hp_milli = d.hp
	player.armor_milli = d.armor
	player.armor_max = d.armor_max
	player.inventory.apply_data(d.inventory)
	player.action = d.action
	player.action_end_tick = d.action_end
	player.action_kind = d.action_kind
	player.last_input_seq = d.ack
	player.recoil = Vector2(d.recoil[0], d.recoil[1])
	var m := player.movement
	m.grounded = d.grounded
	m.crouched = d.crouched
	m.sprinting = d.sprinting
	m.slide_remaining_ticks = d.slide
	m.vault_start = d.vault_start
	m.vault_end = d.vault_end
	m.vault_progress_ticks = d.vault_progress
	m.vaulting = d.vaulting

static func world_data(sim: DuelSimulation, tick: int) -> Dictionary:
	return {"round": sim.round_number, "tick": tick, "players": [player_data(sim.players[0]), player_data(sim.players[1])],
		"items": sim.pickup.items, "projectiles": sim.weapons.projectiles, "grenades": sim.grenade.grenades, "flames": sim.grenade.flames}

static func apply_world(sim: DuelSimulation, data: Dictionary) -> void:
	sim.round_number = data.round
	for slot in 2: apply_player(sim.players[slot], data.players[slot])
	sim.pickup.items = data.items
	sim.weapons.projectiles = data.projectiles
	sim.grenade.grenades = data.grenades
	sim.grenade.flames = data.flames

static func input_data(frame: InputFrame, round_number: int) -> Dictionary:
	return {"seq": frame.seq, "tick": frame.sample_tick, "round": round_number, "x": frame.axes.x, "y": frame.axes.y, "yaw": frame.yaw, "pitch": frame.pitch, "held": frame.held_buttons, "actions": frame.actions}

static func parse_input(data: Dictionary, round_number: int) -> DuelResult:
	for key in ["seq", "tick", "round", "x", "y", "yaw", "pitch", "held", "actions"]:
		if not data.has(key): return DuelResult.failure("INVALID_INPUT")
	if data.round != round_number or not data.seq is int or data.seq < 1 or not data.tick is int or data.tick < 0 or not data.actions is Array or data.actions.size() > 16: return DuelResult.failure("INVALID_INPUT")
	for key in ["x", "y", "yaw", "pitch"]:
		if not (data[key] is float or data[key] is int) or not is_finite(float(data[key])): return DuelResult.failure("INVALID_INPUT")
	if absf(data.x) > 1 or absf(data.y) > 1 or absf(data.pitch) > PI / 2 or not data.held is int or data.held < 0 or data.held > 63: return DuelResult.failure("INVALID_INPUT")
	for action in data.actions:
		if not action is Dictionary or not action.has("kind") or action.kind not in ["cancel", "switch", "grenade", "heal", "reload", "interact", "melee", "fire", "jump", "select_heal", "select_grenade", "throw"] or not action.get("argument", 0) is int: return DuelResult.failure("INVALID_INPUT")
	var f := InputFrame.new()
	f.seq = data.seq
	f.sample_tick = data.tick
	f.axes = Vector2(data.x, data.y).limit_length()
	f.yaw = wrapf(data.yaw, -PI, PI)
	f.pitch = data.pitch
	f.held_buttons = data.held
	f.actions = data.actions
	return DuelResult.success(f)
