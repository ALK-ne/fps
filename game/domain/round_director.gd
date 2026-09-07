class_name RoundDirector
extends RefCounted

var phase: int = CanonicalCodec.Phase.LOBBY
var revision: int = 0
var deadline_tick: int = 0
var first_slot: int = 0
var selected_spawn: Array = [-1, -1]
var rng := RandomNumberGenerator.new()
var config: GameConfig

func begin_round(state: MatchState, seed_value: int) -> MatchEvent:
	rng.seed = seed_value
	first_slot = state.previous_winner if state.previous_winner >= 0 else rng.randi_range(0, 1)
	selected_spawn = [-1, -1]
	return MatchEvent.make(CanonicalCodec.Durable.ROUND_PREPARED, {"round": state.round + 1, "first_slot": first_slot})

func activate(tick: int) -> void:
	_set_phase(CanonicalCodec.Phase.SELECTING_FIRST, tick + 600)

func allowed(slot: int, spawn: int) -> bool:
	if spawn < 0 or spawn > 5: return false
	if phase == CanonicalCodec.Phase.SELECTING_FIRST: return slot == first_slot
	if phase == CanonicalCodec.Phase.SELECTING_SECOND and slot == 1 - first_slot:
		for candidate in config.spawn_pairs[int(selected_spawn[first_slot])]:
			if int(candidate) == spawn: return true
	return false

func accept_spawn(slot: int, spawn_id: int, expected_revision: int, tick: int) -> DuelResult:
	if tick >= deadline_tick or revision != expected_revision or not allowed(slot, spawn_id):
		return DuelResult.failure("INVALID_SPAWN")
	selected_spawn[slot] = spawn_id
	if phase == CanonicalCodec.Phase.SELECTING_FIRST: _set_phase(CanonicalCodec.Phase.SELECTING_SECOND, tick + 600)
	else: _set_phase(CanonicalCodec.Phase.COUNTDOWN, tick + 180)
	return DuelResult.success(to_data())

func step(tick: int) -> Array:
	if tick < deadline_tick: return []
	if phase in [CanonicalCodec.Phase.SELECTING_FIRST, CanonicalCodec.Phase.SELECTING_SECOND]:
		var slot := first_slot if phase == CanonicalCodec.Phase.SELECTING_FIRST else 1 - first_slot
		var choices: Array = []
		for i in 6:
			if allowed(slot, i): choices.append(i)
		if choices.is_empty(): return []
		selected_spawn[slot] = choices[rng.randi_range(0, choices.size() - 1)]
		_set_phase(CanonicalCodec.Phase.SELECTING_SECOND if slot == first_slot else CanonicalCodec.Phase.COUNTDOWN, tick + (600 if slot == first_slot else 180))
		return [to_data()]
	if phase == CanonicalCodec.Phase.COUNTDOWN:
		_set_phase(CanonicalCodec.Phase.FIGHTING, tick + 5400)
		return [to_data()]
	return []

func _set_phase(value: int, deadline: int) -> void:
	phase = value
	deadline_tick = deadline
	revision += 1

func to_data() -> Dictionary:
	return {"phase": phase, "revision": revision, "deadline_tick": deadline_tick, "first_slot": first_slot, "selected_spawn": selected_spawn.duplicate()}
