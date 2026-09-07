class_name DuelSimulation
extends RefCounted

var config: GameConfig
var queries: ArenaQueries
var players: Array[PlayerState] = []
var movement := MovementSolver.new()
var weapons := WeaponSystem.new()
var healing := HealingSystem.new()
var pickup := PickupSystem.new()
var grenade := GrenadeSystem.new()
var round_number: int = 1
var tick: int = 0
var events: Array = []
var melee_requests: Array[int] = []
var throw_requests: Array[int] = []

func setup(cfg: GameConfig, arena_queries: ArenaQueries) -> void:
	config = cfg
	queries = arena_queries
	for system in [movement, weapons, pickup, grenade]:
		system.config = cfg
		system.queries = queries
	healing.config = cfg
	for slot in 2:
		var player := PlayerState.new()
		player.slot = slot
		players.append(player)

func reset_round(number: int, spawn_ids: Array, seed_value: int) -> void:
	round_number = number
	for slot in 2:
		players[slot].reset(number)
		players[slot].position = queries.arena.spawn_position(spawn_ids[slot])
		players[slot].yaw = queries.arena.spawn_yaw(spawn_ids[slot])
		queries.proxies[slot].position = players[slot].position
	weapons.projectiles.clear()
	weapons.next_id = 1
	weapons.round_seed = seed_value
	grenade.grenades.clear()
	grenade.flames.clear()
	grenade.next_id = 1
	pickup.items = LootBuilder.generate(config, seed_value)
	events.clear()

func step(frames: Array, current_tick: int) -> Array:
	tick = current_tick
	events = []
	melee_requests.clear()
	throw_requests.clear()
	weapons.events.clear()
	grenade.events.clear()
	for player in players:
		player.alive_at_start = player.hp_milli > 0
		if not player.alive_at_start: continue
		var frame: InputFrame = frames[player.slot]
		player.yaw = frame.yaw
		player.pitch = clampf(frame.pitch, deg_to_rad(-89), deg_to_rad(89))
		player.last_input_seq = frame.seq
		player.recoil = player.recoil.move_toward(Vector2.ZERO, deg_to_rad(6) / 60.0)
		_cancel_and_actions(player, frame)
	var states: Array = []
	for player in players:
		states.append(movement.step(player, frames[player.slot]) if player.alive_at_start else player.movement)
	var delta: Vector3 = states[1].position - states[0].position
	var horizontal := Vector3(delta.x, 0, delta.z)
	if horizontal.length() < 0.7 and absf(delta.y) < 1.5:
		var correction := (horizontal.normalized() if horizontal.length() > 0.001 else Vector3.RIGHT) * (0.7 - horizontal.length()) * 0.5
		states[0] = queries.move_body(0, states[0], -correction)
		states[1] = queries.move_body(1, states[1], correction)
	for player in players:
		player.movement = states[player.slot]
		queries.proxies[player.slot].position = player.position
		queries.proxies[player.slot].set_crouched(player.movement.crouched)
		if not player.alive_at_start: continue
		weapons.fire(player, frames[player.slot], tick)
		if player.slot in throw_requests: grenade.throw_from(player, tick)
		player.last_fire = frames[player.slot].held(InputFrame.FIRE)
	var damage := weapons.step(tick)
	damage.append_array(grenade.step(players, tick))
	# Apply both accepted melee impulses after movement. The next physics tick
	# resolves wall contact, without braking the new impulse on its release tick.
	for slot in melee_requests:
		var player: PlayerState = players[slot]
		var other: PlayerState = players[1 - slot]
		var offset := other.eye() - player.eye()
		if not player.movement.vaulting and other.alive_at_start and offset.length() <= 1.5 and player.direction().dot(offset.normalized()) >= cos(deg_to_rad(30)) and queries.ray(player.eye(), other.eye()).is_empty():
			other.velocity += Vector3(offset.x, 0, offset.z).normalized() * 5
			events.append({"kind": "melee", "slot": slot})
	events.append_array(DamageSystem.apply(players, damage))
	for player in players:
		weapons.complete(player, tick)
		if healing.complete(player, tick): events.append({"kind": "heal", "slot": player.slot})
	events.append_array(pickup.step(players, frames, tick, round_number))
	events.append_array(weapons.events)
	events.append_array(grenade.events)
	return events

func _cancel_and_actions(player: PlayerState, frame: InputFrame) -> void:
	var a = CanonicalCodec.Action
	if player.movement.vaulting: return
	if not frame.held(InputFrame.SPRINT): player.movement.sprinting = false
	if player.action == a.HEAL and (frame.held(InputFrame.SPRINT) or frame.held(InputFrame.ADS) or frame.held(InputFrame.FIRE)):
		player.action = a.IDLE
	if player.action == a.GRENADE_READY and frame.held(InputFrame.FIRE): player.action = a.GRENADE_AIM
	var priority := {"cancel": 0, "switch": 1, "grenade": 2, "heal": 3, "reload": 4, "interact": 5, "melee": 6, "fire": 7, "throw": 8}
	var actions := frame.actions.duplicate()
	actions.sort_custom(func(x, y): return int(priority.get(x.kind, 99)) < int(priority.get(y.kind, 99)))
	for action in actions:
		var kind: String = action.kind
		var argument := int(action.get("argument", 0))
		if kind == "jump" or kind == "fire" or kind == "interact": continue
		if kind == "select_heal":
			if argument in [1, 2, 3, 4]: player.inventory.selected_heal = argument
			continue
		if kind == "select_grenade":
			if argument in [1, 2]: player.inventory.selected_grenade = argument
			continue
		if kind == "cancel": player.action = a.IDLE
		elif kind == "switch" and argument in [0, 1] and player.inventory.weapons[argument] != null:
			player.action = a.SWITCH
			player.action_kind = argument
			player.action_end_tick = tick + 15
		elif kind == "grenade":
			if player.action in [a.GRENADE_READY, a.GRENADE_AIM]: player.action = a.IDLE
			elif player.inventory.grenades[player.inventory.selected_grenade - 1] > 0: player.action = a.GRENADE_READY
		elif kind == "heal" and player.action not in [a.GRENADE_READY, a.GRENADE_AIM, a.VAULT]: healing.begin(player, argument if argument > 0 else player.inventory.selected_heal, tick)
		elif kind == "reload": weapons.reload_begin(player, tick)
		elif kind == "throw": throw_requests.append(player.slot)
		elif kind == "melee" and player.action == a.IDLE and tick >= player.next_melee_tick:
			player.next_melee_tick = tick + 42
			melee_requests.append(player.slot)
		break
