extends Node

var app: AppContext
var configured_round: int = -1
var ready_since: int = 0
var last_report: int = 0
var finished_match: String = ""

func _physics_process(_delta: float) -> void:
	if app == null: return
	var s := app.session
	if s == null: return
	if s.phase == 8 and app.options.scenario == "rematch":
		if finished_match.is_empty():
			finished_match = str(s.invitation_data.match)
			s.rematch()
	if s.phase in [2, 3]:
		for spawn in 6:
			if s.director.allowed(s.local_slot, spawn):
				s.choose_spawn(s.local_slot, spawn)
				break
	if s.phase == 5:
		if ready_since == 0: ready_since = Time.get_ticks_msec()
		if s.host and app.options.scenario in ["full_match", "rematch"]:
			var sim := s.world.simulation
			if configured_round != s.store.state.round:
				configured_round = s.store.state.round
				sim.players[0].position = Vector3(-8, 0.02, -3)
				sim.players[1].position = Vector3(-8, 0.02, -6)
				sim.players[0].inventory.weapons[0] = {"id": 999, "kind": 1, "magazine": 24, "next_shot_us": 0}
				sim.players[0].inventory.active_slot = 0
				s._send_baseline()
			app.router.yaw = 0
			app.router.pitch = -0.15
			app.router.captured = true
			sim.players[0].recoil = Vector2.ZERO
			Input.action_press("fire")
			Input.action_press("ads")
	if Time.get_ticks_msec() - last_report > 500:
		last_report = Time.get_ticks_msec()
		var result := {"pid": OS.get_process_id(), "role": "host" if s.host else "guest", "connected": s.connected, "phase": s.phase,
			"round": s.store.state.round, "scores": s.store.state.scores, "seq": s.store.state.last_seq, "hash": s.store.state.last_hash.hex_encode(),
			"status": s.status, "tick": s.tick, "tx": s.sent_bytes, "rx": s.received_bytes, "terminal": s.store.state.is_terminal(), "winner": s.store.state.match_winner,
			"hp": [s.world.simulation.players[0].hp_milli,s.world.simulation.players[1].hp_milli], "gun": s.world.simulation.players[0].inventory.active(), "captured": app.router.captured,
			"match": str(s.invitation_data.match), "finished_match": finished_match}
		var path := ProjectSettings.globalize_path("res://").path_join("../artifacts/scenario-" + app.options.profile + ".json").simplify_path()
		var write_started := Time.get_ticks_usec()
		# Readers never open the staging file, so Windows sharing locks cannot
		# stall the simulation while a harness is reading the previous report.
		var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(result))
			file.close()
			if DirAccess.rename_absolute(path + ".tmp", path) != OK:
				push_error("SCENARIO_REPORT_REPLACE_FAILED")
		app._trace_slow("scenario_report", write_started)
		print(JSON.stringify({"scenario": app.options.scenario, "phase": s.phase, "round": s.store.state.round, "seq": s.store.state.last_seq}))
