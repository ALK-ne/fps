extends Node

var app: AppContext
var configured_round: int = -1
var ready_since: int = 0
var last_report: int = 0
var finished_match: String = ""
var last_logged_state: String = ""
var control := TCPServer.new()
var clients: Array = []
var latest_report: Dictionary = {}
var armed: Array = []
var control_token := DuelIds.random_bytes(16).hex_encode()
var last_command_tick: int = -1
var fixture_id: int = 499
var fixture_mode: String = ""
var trace_slot: int = -1
var tick_trace: Array = []

func _ready() -> void:
	if not OS.is_debug_build():
		queue_free()
		return
	var port := app.options.instance_lock_port + 1000
	if control.listen(port, "127.0.0.1") != OK:
		push_error("CONTROL_LISTEN_FAILED")
		return
	print(JSON.stringify({"control_ready": true, "port": port, "pid": OS.get_process_id(), "token": control_token}))

func _process(_delta: float) -> void:
	while control.is_connection_available():
		var peer := control.take_connection()
		if clients.size() >= 4: peer.disconnect_from_host()
		else: clients.append({"peer": peer, "buffer": "", "since": Time.get_ticks_msec()})
	for client in clients.duplicate():
		var peer: StreamPeerTCP = client.peer
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED or Time.get_ticks_msec() - client.since > 2000:
			peer.disconnect_from_host()
			clients.erase(client)
			continue
		var count := peer.get_available_bytes()
		if count == 0: continue
		if count > 4096 or client.buffer.length() + count > 4096:
			peer.disconnect_from_host()
			clients.erase(client)
			continue
		client.buffer += peer.get_utf8_string(count)
		if not client.buffer.contains("\n"): continue
		var request: Variant = JSON.parse_string(client.buffer.get_slice("\n", 0))
		client.buffer = ""
		var response: Dictionary = {"error": "INVALID_COMMAND"}
		if request is Dictionary:
			if request.get("command") == "observe": response = latest_report
			elif request.get("token") == control_token:
				if request.get("command") == "arm" and request.get("actions") is Array and request.actions.size() <= 16 and armed.size() < 16:
					armed.append(request)
					response = {"armed": true}
				elif request.get("command") == "status":
					app.session.check_status()
					response = {"checking": true}
				elif request.get("command") == "fault":
					var files := app.session.store.files
					files.fault_point = str(request.get("point", ""))
					files.fault_record_type = int(request.get("recordType", -1))
					files.fault_occurrence = int(request.get("occurrence", 1))
					files.fault_hits = 0
					response = {"armed": true}
				elif request.get("command") == "fixture" and app.session.host:
					response = _fixture(request)
				elif request.get("command") == "trace":
					response = {"samples": tick_trace.duplicate(true)}
				elif request.get("command") == "resend_action" and not app.session.last_sent_action_request.is_empty():
					app.session._send(20, app.session.last_sent_action_request, 3)
					response = {"resent": true}
		peer.put_data((JSON.stringify(response) + "\n").to_utf8_buffer())

func _fixture(request: Dictionary) -> Dictionary:
	var s := app.session
	var sim := s.world.simulation
	if s.phase != CanonicalCodec.Phase.FIGHTING: return {"error": "WRONG_PHASE"}
	if request.get("case") in ["checkpoint", "checkpoint_keep"]:
		fixture_mode = request.case
		s.phase = CanonicalCodec.Phase.RESOLVING
		s.director.phase = s.phase
		return {"configured": true}
	if request.get("case") == "close_round":
		sim.players[1].hp_milli = 0
		return {"configured": true}
	if request.get("case") not in ["pickup_empty", "pickup_hold", "ammo_cap", "frag", "incendiary"]: return {"error": "UNKNOWN_FIXTURE"}
	var slot := int(request.get("slot", 1))
	if slot not in [0, 1]: return {"error": "INVALID_SLOT"}
	var weapon_kind := int(request.get("weaponKind", 1))
	if weapon_kind not in [1, 2, 3]: return {"error": "INVALID_WEAPON"}
	fixture_id += 1
	trace_slot = slot if request.case == "pickup_hold" else -1
	tick_trace.clear()
	for player in sim.players:
		var revision := player.inventory.revision
		player.reset(1)
		player.inventory.revision = revision + 1
		player.position = Vector3(-8, 0.02, -3 if player.slot == slot else 3)
		player.yaw = 0
		sim.queries.proxies[player.slot].position = player.position
	sim.pickup.items = [{"id": fixture_id, "revision": 0, "kind": 1, "subtype": 1, "amount": 1, "position": sim.players[slot].eye() + Vector3.FORWARD * 0.8, "weapon": {"id": fixture_id, "kind": 1, "magazine": 7, "next_shot_us": 0}}]
	sim.pickup.next_id = fixture_id + 1
	if request.case == "pickup_hold":
		sim.pickup.items[0].revision = 7
		sim.players[slot].inventory.weapons = [{"id": fixture_id + 1000, "kind": 1, "magazine": 11, "next_shot_us": 0}, {"id": fixture_id + 2000, "kind": 3, "magazine": 5, "next_shot_us": 0}]
		sim.players[slot].inventory.active_slot = 0
	if request.case == "ammo_cap":
		sim.players[slot].inventory.reserve[weapon_kind - 1] = int(s.config.weapon(weapon_kind).reserveCap) - 1
		sim.pickup.items[0].merge({"kind": 2, "subtype": weapon_kind, "amount": 2}, true)
		sim.pickup.items[0].erase("weapon")
	if request.case in ["frag", "incendiary"]:
		sim.pickup.items.clear()
		var kind := 1 if request.case == "frag" else 2
		sim.players[slot].inventory.grenades[kind - 1] = 1
		sim.players[slot].inventory.selected_grenade = kind
	s._send_baseline()
	app.router.yaw = 0
	app.router.pitch = 0
	return {"configured": true, "id": fixture_id}

func _physics_process(_delta: float) -> void:
	if app == null: return
	var s := app.session
	if s == null: return
	if trace_slot >= 0 and s.host:
		var player: PlayerState = s.world.simulation.players[trace_slot]
		tick_trace.append({"tick": s.tick, "action": player.action, "end_tick": player.action_end_tick, "revision": player.inventory.revision, "weapon": player.inventory.active().get("id", 0), "latched": player.interact_latched})
		if tick_trace.size() > 256: tick_trace.pop_front()
	if fixture_mode == "checkpoint_keep" and s.host and s.awaiting.is_empty():
		var state := s.store.state
		if state.round_status == "OPEN":
			s._commit(MatchEvent.make(4, {"round": state.round, "winner": -1, "reason": 1, "closed_tick": s.tick}), "fixture")
		elif state.round_status == "CLOSED":
			var old_epoch := state.last_recovery_epoch + 1
			var final_receipt := state.last_seq + 1 >= 1024
			if final_receipt: fixture_mode = ""
			s._commit(MatchEvent.make(5, {"round": state.round, "old_epoch": old_epoch, "new_epoch": old_epoch + 1, "recovery_id": DuelIds.recovery_id(state.match_id, old_epoch).hex_encode(), "offender": -1, "disposition": 1}), "prepare" if final_receipt else "fixture")
	if fixture_mode == "checkpoint" and s.host and s.awaiting.is_empty():
		var state := s.store.state
		if state.round_status == "OPEN":
			s._commit(MatchEvent.make(4, {"round": state.round, "winner": -1, "reason": 1, "closed_tick": s.tick}), "prepare" if state.round == 128 else "fixture")
			if state.round == 128: fixture_mode = ""
		elif state.round_status == "CLOSED": s._commit(MatchEvent.make(2, {"round": state.round + 1, "first_slot": state.round % 2}), "fixture")
		elif state.round_status == "PREPARED": s._commit(MatchEvent.make(3, {"round": state.prepared_round}), "fixture")
	for command in armed.duplicate():
		if s.tick < int(command.get("tick", 0)): continue
		for action in command.actions:
			if not action is Dictionary or not InputMap.has_action(str(action.get("action", ""))): continue
			var event := InputEventAction.new()
			event.action = action.action
			event.pressed = bool(action.get("pressed", true))
			app.router.handle(event)
			if event.pressed: Input.action_press(event.action)
			else: Input.action_release(event.action)
		last_command_tick = s.tick
		armed.erase(command)
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
		var result := {"pid": OS.get_process_id(), "scenario": app.options.scenario, "role": "host" if s.host else "guest", "connected": s.connected, "phase": s.phase,
			"round": s.store.state.round, "scores": s.store.state.scores, "seq": s.store.state.last_seq, "hash": s.store.state.last_hash.hex_encode(),
			"status": s.status, "tick": s.tick, "tx": s.sent_bytes, "rx": s.received_bytes, "terminal": s.store.state.is_terminal(), "winner": s.store.state.match_winner,
			"hp": [s.world.simulation.players[0].hp_milli,s.world.simulation.players[1].hp_milli], "gun": s.world.simulation.players[0].inventory.active(), "captured": app.router.captured,
			"match": str(s.invitation_data.match), "finished_match": finished_match,
			"diagnostic": s.diagnostic_only, "result_status": s.terminal_status.get("resultStatus", 0), "notice_id": s.terminal_status.get("noticeId", PackedByteArray()).hex_encode(), "started": s.started, "max_poll_gap_ms": s.max_poll_gap_ms, "slow_sections_ms": app.slow_sections,
			"recovery_expired": s.recovery.expired, "tombstone": FileAccess.file_exists(s.store.root + "/terminal.json.a") or FileAccess.file_exists(s.store.root + "/terminal.json.b")}
		result.profile = app.options.profile
		result.protocol = 2
		result.store_schema = 2
		result.rules_hash = app.config.rules_hash.hex_encode()
		result.map_hash = app.config.map_hash.hex_encode()
		result.sent_types = s.sent_types
		result.received_types = s.received_types
		result.checkpoint_seq = s.store.checkpoint_seq
		result.event_types = s.journal.event_types if s.host else s.replica.event_types
		result.actions = [s.world.simulation.players[0].action, s.world.simulation.players[1].action]
		result.entity_ids = {"projectiles": s.world.simulation.weapons.projectiles.map(func(p): return p.id), "grenades": s.world.simulation.grenade.grenades.map(func(p): return p.id), "flames": s.world.simulation.grenade.flames.map(func(p): return p.id)}
		result.inventories = [s.world.simulation.players[0].inventory.to_data(), s.world.simulation.players[1].inventory.to_data()]
		result.action_result = s.last_action_result
		result.action_highwater = s.action_ledger.highwater
		result.action_results_count = s.action_ledger.results.size()
		result.items = s.world.simulation.pickup.items.map(func(item): return {"id": item.id, "amount": item.amount, "revision": item.revision, "weapon": item.get("weapon", {})})
		result.event_sequence = s.journal.sequence if s.host else s.replica.sequence
		result.last_command_tick = last_command_tick
		latest_report = result.duplicate(true)
		var logged_state := JSON.stringify({"scenario": app.options.scenario, "phase": s.phase, "round": s.store.state.round, "seq": s.store.state.last_seq})
		if logged_state != last_logged_state:
			last_logged_state = logged_state
			print(logged_state)
