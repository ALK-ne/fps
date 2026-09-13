class_name DuelSession
extends RefCounted

signal status_changed(message: String)
signal phase_changed
signal authenticated
signal world_received(data: Dictionary)
signal game_events(events: Array)

var config: GameConfig
var profile: DuelProfile
var clock: DuelClock
var transport := ENetTransport.new()
var store := RecoveryStore.new()
var director := RoundDirector.new()
var recovery := RecoveryCoordinator.new()
var prediction := Prediction.new()
var world: WorldView
var invitation_data: Dictionary = {}
var session_data: Dictionary = {}
var peers: Dictionary = {}
var active_peer: ENetPacketPeer
var host: bool = false
var connected: bool = false
var started: bool = false
var local_slot: int = 0
var epoch: int = 0
var tick: int = 0
var phase: int = CanonicalCodec.Phase.LOBBY
var status: String = ""
var remote_input := InputFrame.new()
var remote_input_ms: int = 0
var remote_last_seq: int = 0
var last_action_seq: int = 0
var pending_actions: Array = []
var action_window_ms: int = 0
var action_window_count: int = 0
var last_receive_ms: int = 0
var last_heartbeat_ms: int = 0
var connect_started_ms: int = 0
var last_retry_ms: int = 0
var awaiting: String = ""
var awaited_seq: int = 0
var baseline_ready: bool = false
var baseline_hash: PackedByteArray
var baseline_id: int = 0
var baseline_request_id: int = 0
var cached_baseline: Dictionary = {}
var journal := EventJournal.new()
var replica := EntityReplica.new()
var baseline_requester := BaselineRequester.new()
var pending_snapshot: Dictionary = {}
var last_poll_ms: int = 0
var max_poll_gap_ms: int = 0
var last_snapshot_tick: int = -1
var remote_resume: Dictionary = {}
var local_continuous: bool = true
var resuming: bool = false
var rematch_ready: Array = [false, false]
var sent_bytes: int = 0
var received_bytes: int = 0
var rtt_ms: float = 0
var last_world_signature: String = ""
var lobby_ready: Array = [false, false]
var spawn_request_id: int = 0
var last_spawn_request: int = 0
var recent_inputs: Array = []
var input_round: int = -1
var pending_checkpoint_hash: PackedByteArray
var action_ledger := ActionLedger.new()
var next_action_id: int = 0
var local_actions: Dictionary = {}
var active_swap: Dictionary = {}
var last_action_result: Dictionary = {}
var last_sent_action_request: Dictionary = {}
var diagnostic_only: bool = false
var diagnostic_until_ms: int = 0
var terminal_status: Dictionary = {}
var status_request_id: PackedByteArray = PackedByteArray()
var graceful_slot: int = -1
var old_connection_epoch: int = 0
var phase_buffer: Array = []
var phase_buffer_bytes: int = 0
var sent_types: Dictionary = {}
var received_types: Dictionary = {}
var debug_drop_types: Dictionary = {}
var debug_dropped_types: Dictionary = {}

func setup(cfg: GameConfig, user: DuelProfile, game_clock: DuelClock, view: WorldView) -> void:
	config = cfg
	profile = user
	clock = game_clock
	world = view
	world.prediction = prediction
	director.config = cfg
	recovery.clock = clock
	recovery.store = store

func create_room(address: String = "127.0.0.1", port: int = 27840) -> DuelResult:
	host = true
	local_slot = 0
	world.local_slot = 0
	invitation_data = {"v": 2, "match": DuelIds.random_bytes(16).hex_encode(), "host": address, "port": port,
		"secret": DuelIds.random_bytes(32).hex_encode(), "rules": config.rules_hash.hex_encode(), "map": config.map_hash.hex_encode()}
	store.initialize(profile, str(invitation_data.match).hex_decode())
	session_data = {"invitation": invitation_data, "host": true, "host_id": profile.player_id, "guest_id": PackedByteArray(),
		"host_boot": profile.boot_id, "guest_boot": PackedByteArray(), "epoch": 0}
	var saved := _save_session()
	if not saved.ok: return saved
	var r := transport.listen(invitation_data)
	if r.ok:
		started = true
		_set_status("部屋を作成しました。招待コードを相手に渡してください。")
	return r

func join_room(code: String) -> DuelResult:
	var parsed := DuelAuth.parse_invitation(code.strip_edges(), config)
	if not parsed.ok: return parsed
	host = false
	local_slot = 1
	world.local_slot = 1
	invitation_data = parsed.value
	var closed_match := profile.closed.lookup(str(invitation_data.match).hex_decode())
	if closed_match.ok: return DuelResult.failure("TERMINAL")
	if closed_match.error_code != "NOT_FOUND": return closed_match
	store.initialize(profile, str(invitation_data.match).hex_decode())
	if FileAccess.file_exists(store.root + "/session.json.a") or FileAccess.file_exists(store.root + "/session.json.b"): return DuelResult.failure("USE_SAVED_RESUME")
	session_data = {"invitation": invitation_data, "host": false, "host_id": PackedByteArray(), "guest_id": profile.player_id,
		"host_boot": PackedByteArray(), "guest_boot": profile.boot_id, "epoch": 0}
	connect_started_ms = Time.get_ticks_msec()
	started = true
	_set_status("接続しています…")
	return transport.connect_to(invitation_data)

func restore() -> DuelResult:
	var current := profile.files.load_ab(profile.root + "/current-match.json")
	if not current.ok: return current
	if not StoreSchema.bytes(current.value.value, 16): return DuelResult.failure("STORE_CORRUPT")
	var mid: PackedByteArray = current.value.value
	store.initialize(profile, mid)
	var saved := store.files.load_ab(store.root + "/session.json")
	if not saved.ok: return saved
	if not saved.value.value is Dictionary: return DuelResult.failure("STORE_CORRUPT")
	var decoded_session := StoreSchema.session_data(saved.value.value, profile.player_id)
	if not decoded_session.ok:
		if decoded_session.error_code == "LEGACY_SCHEMA":
			var old_history := store.load_match(mid)
			if not old_history.ok: return old_history
		return decoded_session
	session_data = decoded_session.value
	invitation_data = session_data.invitation
	if invitation_data.match != mid.hex_encode(): return DuelResult.failure("HISTORY_FORK")
	if invitation_data.get("v") != 2: return DuelResult.failure("LEGACY_SCHEMA")
	if invitation_data.rules != config.rules_hash.hex_encode(): return DuelResult.failure("VERSION_MISMATCH")
	if invitation_data.map != config.map_hash.hex_encode(): return DuelResult.failure("VERSION_MISMATCH")
	var terminal := store.files.load_ab(store.root + "/terminal.json")
	if not terminal.ok and terminal.error_code != "NOT_FOUND": return terminal
	var history := store.load_match(mid)
	if not history.ok: return history
	if store.legacy: return DuelResult.failure("LEGACY_SCHEMA")
	if terminal.ok:
		if not terminal.value.value is Dictionary or not StoreSchema.exact(terminal.value.value, ["policy", "status"]) or terminal.value.value.policy != GameConfig.RECOVERY_POLICY or not terminal.value.value.status is Dictionary or not store.validate_terminal_notice(terminal.value.value.status): return DuelResult.failure("STORE_CORRUPT")
		terminal_status = terminal.value.value.status
		if session_data.host and terminal_status.resultStatus == 1 and not store.state.is_terminal():
			var finalized := store.persist_terminal_notice(terminal_status, true, int(session_data.epoch))
			if not finalized.ok: return finalized
		diagnostic_only = true
	host = session_data.host
	local_slot = 0 if host else 1
	world.local_slot = local_slot
	epoch = int(session_data.epoch)
	old_connection_epoch = epoch
	var observation := store.files.load_ab(store.root + "/observations/%d.json" % epoch)
	if not observation.ok and observation.error_code != "NOT_FOUND": return observation
	if observation.ok:
		if not StoreSchema.observation(observation.value.value, epoch): return DuelResult.failure("STORE_CORRUPT")
		recovery.observation = observation.value.value
	if store.state.is_terminal() and terminal_status.is_empty():
		terminal_status = RecoveryStatus.create(store.state, maxi(1, epoch), profile.boot_id, recovery.observation, "TERMINAL", -1)
		diagnostic_only = true
	resuming = true
	local_continuous = false
	recovery.suspended = true
	phase = CanonicalCodec.Phase.SUSPENDED
	started = true
	connect_started_ms = Time.get_ticks_msec()
	diagnostic_until_ms = connect_started_ms + 30000
	_set_status("保存した接続先へ復帰しています…")
	return transport.listen(invitation_data) if host else transport.connect_to(invitation_data)

func _save_session() -> DuelResult:
	var value := StoreSchema.session_value(session_data)
	var valid := StoreSchema.session_data(value, profile.player_id)
	if not valid.ok: return valid
	var saved := store.files.save_ab(store.root + "/session.json", value)
	if not saved.ok: return saved
	return profile.files.save_ab(profile.root + "/current-match.json", str(invitation_data.match).hex_decode())

func poll() -> void:
	if not started: return
	var now := Time.get_ticks_msec()
	if diagnostic_until_ms > 0 and now >= diagnostic_until_ms:
		transport.close()
		connected = false
		started = false
		peers.clear()
		active_peer = null
		_set_status(RecoveryStatus.message(terminal_status))
		phase_changed.emit()
		return
	if last_poll_ms > 0: max_poll_gap_ms = maxi(max_poll_gap_ms, now - last_poll_ms)
	last_poll_ms = now
	for e in transport.poll_nonblocking():
		if e.type == "connect": _on_connect(e.peer)
		elif e.type == "disconnect":
			if e.peer == active_peer: _lost()
			peers.erase(e.peer)
		elif e.type == "packet": _packet(e.peer, e.channel, e.bytes)
		elif e.type == "error" and connected: _lost()
	for peer in peers.keys():
		var info: Dictionary = peers[peer]
		if not info.auth and now - int(info.start) >= 3000:
			peer.peer_disconnect_now()
			peers.erase(peer)
	if connected:
		if now - last_receive_ms >= 2000: _lost()
		elif now - last_heartbeat_ms >= 500:
			last_heartbeat_ms = now
			_send(5, {"sent": now, "echo": 0, "tick": tick}, 0, false)
	elif not host and resuming and now - last_retry_ms >= 500 and (diagnostic_only or (not recovery.expired and not recovery.conflict)):
		last_retry_ms = now
		if peers.is_empty(): transport.connect_to(invitation_data)
	elif not host and not resuming and now - connect_started_ms >= 8000:
		_set_status("接続できません。IP・ファイアウォールを確認するか補助ネットワークを利用してください。")
		transport.close()
		started = false
	if recovery.suspended and local_continuous and not diagnostic_only:
		for event in recovery.step(clock.monotonic_us(), clock.utc_ms()):
			if event in ["RECOVERY_EXPIRED", "CLOCK_UNCERTAIN", "STORE_WRITE_FAILED"]:
				_stop_conflict(event)

func _on_connect(peer: ENetPacketPeer) -> void:
	if peers.size() >= 4 or (connected and active_peer != peer):
		peer.peer_disconnect_now()
		return
	peers[peer] = {"codec": PacketCodec.new(), "auth": false, "stage": 0, "start": Time.get_ticks_msec(),
		"key": str(invitation_data.secret).hex_decode(), "host_nonce": PackedByteArray(), "guest_nonce": PackedByteArray(),
		"packets": 0, "bytes": 0, "window": Time.get_ticks_msec(), "early": [], "early_bytes": 0}
	if not host:
		var info: Dictionary = peers[peer]
		info.guest_nonce = DuelIds.random_bytes(32)
		_send_to(peer, 1, {"player": profile.player_id, "boot": profile.boot_id, "nonce": info.guest_nonce, "rules": config.rules_hash, "map": config.map_hash}, 0, true, 0)

func _packet(peer: ENetPacketPeer, channel: int, bytes: PackedByteArray) -> void:
	if not peers.has(peer): return
	var info: Dictionary = peers[peer]
	var now := Time.get_ticks_msec()
	if now - int(info.window) >= 2000:
		info.window = now
		info.packets = 0
		info.bytes = 0
	info.packets += 1
	info.bytes += bytes.size()
	if info.packets > (480 if info.auth else 20) or info.bytes > (262144 if info.auth else 24000):
		if OS.is_debug_build(): print(JSON.stringify({"rate_limit": true, "packets": info.packets, "bytes": info.bytes, "auth": info.auth}))
		peer.peer_disconnect_now()
		return
	var codec: PacketCodec = info.codec
	received_bytes += bytes.size()
	var decoded := codec.decode(bytes, info.key, str(invitation_data.match).hex_decode(), channel, epoch if info.auth else -1)
	if not decoded.ok:
		if OS.is_debug_build() and decoded.error_code != "FRAGMENT_PENDING": print(JSON.stringify({"packet_rejected": decoded.error_code, "channel": channel}))
		return
	var packet: Dictionary = decoded.value
	if packet.slot != 1 - local_slot: return
	# Session-key packets on other channels may overtake Authenticated.
	# Retain bounded raw payloads, then apply the normal policy after binding.
	if not info.auth and not host and info.stage == 1 and packet.kind > 4:
		if packet.epoch == epoch and info.early.size() < 16 and info.early_bytes + packet.payload.size() <= 16384:
			info.early.append({"kind": packet.kind, "payload": packet.payload, "channel": channel, "received": now})
			info.early_bytes += packet.payload.size()
		return
	_receive_payload(peer, packet.kind, channel, packet.slot, packet.payload, packet.epoch)

func _receive_payload(peer: ENetPacketPeer, kind: int, channel: int, slot: int, payload: PackedByteArray, packet_epoch: int) -> void:
	var info: Dictionary = peers[peer]
	var packet := {"kind": kind, "slot": slot, "payload": payload, "epoch": packet_epoch}
	if packet.kind in ControlWire.TYPES or packet.kind == 11:
		var expected: int = (1 if info.stage == 0 else 3) if host else (2 if info.stage == 0 else 4)
		var gate := MessagePolicy.envelope(packet.kind, channel, packet.slot, info.auth, phase, expected)
		if gate.error_code == "WRONG_PHASE" and packet.kind == 24 and phase in [2, 3]:
			if phase_buffer.size() < 16 and phase_buffer_bytes + payload.size() <= 16384:
				phase_buffer.append({"payload": payload, "epoch": packet_epoch, "received": Time.get_ticks_msec()})
				phase_buffer_bytes += payload.size()
			else: replica.request_reason = 5
			return
		if not gate.ok and gate.error_code != "WRONG_PHASE": return
		if gate.error_code == "WRONG_PHASE" and packet.kind not in [20, 23, 50]: return
	if packet.kind != 11 and packet.kind not in ControlWire.TYPES: return
	var data := SnapshotCodec.decode(packet.payload) if packet.kind == 11 else ControlWire.decode(packet.kind, packet.payload)
	if not data.ok or not data.value is Dictionary:
		if OS.is_debug_build(): print(JSON.stringify({"payload_rejected": data.error_code, "kind": packet.kind, "bytes": packet.payload.size()}))
		return
	if not info.auth:
		received_types[packet.kind] = int(received_types.get(packet.kind, 0)) + 1
		_handshake(peer, packet.kind, data.value, packet.epoch)
		return
	if peer != active_peer or packet.slot != 1 - local_slot: return
	last_receive_ms = Time.get_ticks_msec()
	if diagnostic_only and packet.kind not in [5, 32, 41, 43, 44, 45]: return
	received_types[packet.kind] = int(received_types.get(packet.kind, 0)) + 1
	_dispatch(packet.kind, data.value)

func _bytes(d: Dictionary, name: String, size: int) -> bool:
	return d.has(name) and d[name] is PackedByteArray and d[name].size() == size

func _handshake(peer: ENetPacketPeer, kind: int, d: Dictionary, packet_epoch: int) -> void:
	var info: Dictionary = peers[peer]
	if host and kind == 1 and info.stage == 0:
		if not _bytes(d, "player", 16) or not _bytes(d, "boot", 16) or not _bytes(d, "nonce", 32) or d.get("rules") != config.rules_hash or d.get("map") != config.map_hash: return
		if not session_data.guest_id.is_empty() and d.player != session_data.guest_id: return
		if maxi(epoch, int(session_data.epoch)) >= 0xffffffff:
			_stop_conflict("EPOCH_EXHAUSTED")
			return
		epoch = maxi(epoch, int(session_data.epoch)) + 1
		session_data.epoch = epoch
		if not _save_session().ok:
			_stop_conflict("STORE_WRITE_FAILED")
			return
		info.guest_nonce = d.nonce
		info.host_nonce = DuelIds.random_bytes(32)
		info.guest_id = d.player
		info.guest_boot = d.boot
		_send_to(peer, 2, {"player": profile.player_id, "boot": profile.boot_id, "nonce": info.host_nonce, "echo": info.guest_nonce, "epoch": epoch}, 0, true)
		info.key = DuelAuth.session_key(str(invitation_data.secret).hex_decode(), str(invitation_data.match).hex_decode(), epoch, info.host_nonce, info.guest_nonce, profile.boot_id, d.boot)
		info.stage = 1
	elif not host and kind == 2 and info.stage == 0:
		if not _bytes(d, "player", 16) or not _bytes(d, "boot", 16) or not _bytes(d, "nonce", 32) or d.get("echo") != info.guest_nonce or not d.get("epoch") is int or d.epoch < int(session_data.epoch) or d.epoch != packet_epoch: return
		if not session_data.host_id.is_empty() and d.player != session_data.host_id: return
		epoch = d.epoch
		info.host_nonce = d.nonce
		info.host_id = d.player
		info.host_boot = d.boot
		info.key = DuelAuth.session_key(str(invitation_data.secret).hex_decode(), str(invitation_data.match).hex_decode(), epoch, info.host_nonce, info.guest_nonce, d.boot, profile.boot_id)
		info.stage = 1
		_send_to(peer, 3, {"host_nonce": info.host_nonce, "guest_nonce": info.guest_nonce}, 0, true)
	elif host and kind == 3 and info.stage == 1:
		if d.get("host_nonce") != info.host_nonce or d.get("guest_nonce") != info.guest_nonce or packet_epoch != epoch: return
		if not _bind(peer): return
		_send(4, {"epoch": epoch, "guest": info.guest_id, "seq": store.state.last_seq, "hash": store.state.last_hash}, 0, true)
		if resuming or store.state.last_seq > 0: _begin_resume()
		else:
			lobby_ready[0] = true
			_send(6, {"ready": true})
	elif not host and kind == 4 and info.stage == 1:
		if d.get("guest") != profile.player_id or d.get("epoch") != epoch: return
		if not _bind(peer): return
		if resuming: _begin_resume()
		else:
			lobby_ready[1] = true
			_send(6, {"ready": true})
		var early: Array = info.early
		info.early = []
		info.early_bytes = 0
		for message in early:
			if Time.get_ticks_msec() - message.received <= 3000:
				_receive_payload(peer, message.kind, message.channel, 0, message.payload, epoch)

func _bind(peer: ENetPacketPeer) -> bool:
	var info: Dictionary = peers[peer]
	info.auth = true
	active_peer = peer
	connected = true
	last_receive_ms = Time.get_ticks_msec()
	_set_status("認証済み・同期中")
	if not resuming and store.state.last_seq == 0:
		if host:
			session_data.guest_id = info.guest_id
			session_data.guest_boot = info.guest_boot
		else:
			session_data.host_id = info.host_id
			session_data.host_boot = info.host_boot
		session_data.epoch = epoch
		if not _save_session().ok:
			info.auth = false
			connected = false
			active_peer = null
			_stop_conflict("STORE_WRITE_FAILED")
			return false
	authenticated.emit()
	return true

func _send_to(peer: ENetPacketPeer, kind: int, data: Dictionary, channel: int, reliable: bool, forced_epoch: int = -1) -> void:
	if not peers.has(peer): return
	if OS.is_debug_build() and int(debug_drop_types.get(kind, 0)) > 0:
		debug_drop_types[kind] -= 1
		debug_dropped_types[kind] = int(debug_dropped_types.get(kind, 0)) + 1
		return
	var info: Dictionary = peers[peer]
	if kind != 11 and kind not in ControlWire.TYPES: return
	var payload := SnapshotCodec.encode(data) if kind == 11 else PackedByteArray()
	if kind in ControlWire.TYPES:
		channel = MessagePolicy.TABLE[kind][0]
		var encoded := ControlWire.encode(kind, data, store)
		if not encoded.ok:
			push_error("Control encode %d: %s" % [kind, encoded.error_code])
			return
		payload = encoded.value
	var packets: Array = info.codec.encode(kind, payload, str(invitation_data.match).hex_decode(), epoch if forced_epoch < 0 else forced_epoch, local_slot, channel, info.key)
	if packets.is_empty():
		_stop_conflict("PACKET_ENCODING_LIMIT")
		return
	sent_types[kind] = int(sent_types.get(kind, 0)) + 1
	for bytes in packets:
		var result := transport.send(peer, channel, bytes, reliable)
		if result.ok: sent_bytes += bytes.size()

func _send(kind: int, data: Dictionary, channel: int = 0, reliable: bool = true) -> void:
	if active_peer != null: _send_to(active_peer, kind, data, channel, reliable)

func _dispatch(kind: int, d: Dictionary) -> void:
	match kind:
		6:
			lobby_ready[1 - local_slot] = d.ready
			if host and lobby_ready == [true, true] and store.state.last_seq == 0: _create_match()
		5:
			if d.get("echo", 0) > 0: rtt_ms = lerpf(rtt_ms, Time.get_ticks_msec() - int(d.echo), 0.2)
			else: _send(5, {"sent": Time.get_ticks_msec(), "echo": int(d.get("sent", 0)), "tick": tick}, 0, false)
		10:
			if not host or phase != CanonicalCodec.Phase.FIGHTING: return
			var r := Replication.parse_input(d, store.state.round)
			if r.ok and r.value.seq > remote_last_seq and abs(r.value.sample_tick - tick) <= 12:
				remote_input = r.value
				remote_last_seq = remote_input.seq
				remote_input_ms = Time.get_ticks_msec()
		20:
			if not host: return
			var now := Time.get_ticks_msec()
			if now - action_window_ms >= 1000:
				action_window_ms = now
				action_window_count = 0
			action_window_count += 1
			if action_window_count > 120:
				if active_peer != null: active_peer.peer_disconnect_now()
				return
			if action_ledger.round_number != store.state.round: action_ledger.reset(store.state.round)
			var result := action_ledger.begin(d.round, d.actionId, tick, world.simulation.players[1].inventory.revision)
			if result.has("result"): _send(21, result.result, 3)
			elif result.execute:
				if phase != CanonicalCodec.Phase.FIGHTING: _complete_action(d.actionId, 1)
				elif abs(d.sampleTick - tick) > 12: _complete_action(d.actionId, 9)
				else: pending_actions.append(d)
		21:
			if host or d.round != store.state.round or not local_actions.has(d.actionId): return
			local_actions.erase(d.actionId)
			last_action_result = d
		11:
			if host or not d.has("players") or d.get("round") != store.state.round or int(d.get("tick", -1)) <= maxi(last_snapshot_tick, int(pending_snapshot.get("tick", -1))): return
			pending_snapshot = d
		22:
			if not host:
				replica.events(d, world.simulation, Time.get_ticks_msec())
				_present_replica()
		12:
			if not host: replica.correction(d, world.simulation, Time.get_ticks_msec())
		23:
			if host or store.state.is_terminal() or not d.has("phase") or not d.has("revision") or d.get("round") != store.state.round: return
			if d.revision <= director.revision: return
			director.phase = d.phase
			director.revision = d.revision
			director.deadline_tick = d.deadline_tick
			director.first_slot = d.first_slot
			director.selected_spawn = d.selected_spawn
			tick = int(d.get("tick", tick))
			phase = d.phase
			phase_changed.emit()
			if phase in [4, 5]:
				var buffered := phase_buffer
				phase_buffer = []
				phase_buffer_bytes = 0
				for message in buffered:
					if Time.get_ticks_msec() - message.received <= 3000: _receive_payload(active_peer, 24, 3, 0, message.payload, message.epoch)
					else: replica.request_reason = 5
		24:
			if host or store.state.is_terminal() or d.get("round") != store.state.round: return
			if d.baselineId == replica.baseline_id and d.hash == baseline_hash:
				_send(25, {"round": d.round, "baselineId": d.baselineId, "hash": d.hash}, 3)
				return
			var initialize_camera := not baseline_ready
			var newer_players: Array = []
			if last_snapshot_tick > d.tick:
				for player in world.simulation.players: newer_players.append(Replication.player_data(player))
			if not replica.install(d, world.simulation): return
			for player in newer_players: Replication.apply_player(world.simulation.players[player.slot], player)
			prediction.reset()
			if initialize_camera:
				world.remote_interpolation.clear()
				tick = d.tick
			baseline_ready = true
			baseline_hash = d.hash
			baseline_requester.complete()
			_send(25, {"round": d.round, "baselineId": d.baselineId, "hash": d.hash}, 3)
			world_received.emit(EntityWire.world(d))
			_present_replica()
		25:
			if host and d.round == store.state.round and d.baselineId == baseline_id and d.hash == baseline_hash: baseline_ready = true
		26:
			if not host or d.round != store.state.round or d.requestId < baseline_request_id: return
			if d.requestId == baseline_request_id and not cached_baseline.is_empty(): _send(24, cached_baseline, 3)
			else:
				baseline_request_id = d.requestId
				_send_baseline()
		30:
			if host or not d.get("record") is PackedByteArray: return
			var previous_round := store.state.round
			var previous_seq := store.state.last_seq
			var r := store.append_raw(d.record)
			if not r.ok:
				_stop_conflict(r.error_code)
				return
			if store.state.last_seq > previous_seq and d.record[90] == CanonicalCodec.Durable.ROUND_CLOSED:
				phase = store.state.phase
				phase_changed.emit()
			if store.state.round != previous_round:
				replica.reset(store.state.round)
				baseline_requester.reset()
				director.revision = 0
				last_snapshot_tick = -1
				prediction.reset()
				baseline_ready = false
			store.files._fault("before_ack")
			_send(31, {"seq": store.state.last_seq, "hash": store.state.last_hash, "epoch": epoch}, 3)
			store.files._fault("after_ack")
			if resuming and store.state.last_recovery_epoch > 0:
				if local_continuous and (recovery.remaining_ms() <= 0 or clock.is_uncertain()): _stop_conflict("RECOVERY_EXPIRED")
				else: _finish_resume()
			if store.state.is_terminal():
				var indexed := profile.record_closed(store.state.match_id, 1, 1 if store.state.terminal_reason == "DISCONNECT_TIMEOUT" else (2 if store.state.match_winner < 0 else 3))
				if not indexed.ok:
					_stop_conflict("STORE_WRITE_FAILED")
					return
				phase = CanonicalCodec.Phase.MATCH_RESULT
				phase_changed.emit()
		31:
			if not host or d.get("epoch") != epoch or d.get("seq") != awaited_seq or d.get("hash") != store.state.last_hash: return
			if int(d.ackKind) != (1 if awaiting == "checkpoint" else 0): return
			if awaiting == "checkpoint" and d.checkpointHash != pending_checkpoint_hash: return
			var next := awaiting
			awaiting = ""
			_after_ack(next)
		32:
			if not resuming: return
			remote_resume = d
			if diagnostic_only or d.get("terminal", false):
				diagnostic_only = true
				phase = CanonicalCodec.Phase.CONFLICT
				if diagnostic_until_ms == 0: diagnostic_until_ms = Time.get_ticks_msec() + 30000
				_request_status()
				return
			if host: _reconcile()
		33:
			if not d.get("from") is int: return
			if int(d.from) > 1 and store.hash_at(int(d.from) - 1) != d.hash:
				_stop_conflict("HISTORY_FORK")
				return
			var history := store.history_after(maxi(0, int(d.from) - 1))
			if not history.ok:
				_stop_conflict(history.error_code)
				return
			for record in history.value: _send(34, {"record": record}, 3)
			_send(34, {"done": true, "seq": store.state.last_seq, "hash": store.state.last_hash}, 3)
		34:
			if not resuming: return
			if d.has("record"):
				var r := store.append_raw(d.record)
				if not r.ok: _stop_conflict(r.error_code)
			elif d.get("done", false):
				if d.get("seq") != store.state.last_seq or d.get("hash") != store.state.last_hash: _stop_conflict("HISTORY_FORK")
				else:
					_send(32, _resume_data(), 3)
					if host: _reconcile()
		35:
			if host or not resuming or d.get("base_hash") != store.state.last_hash: return
			if d.new_epoch != epoch or d.base_seq != store.state.last_seq or d.round != store.state.round or d.recovery_id != DuelIds.recovery_id(store.state.match_id, d.old_epoch).hex_encode(): return
			if local_continuous and (recovery.remaining_ms() <= 0 or clock.is_uncertain()):
				_stop_conflict("RECOVERY_EXPIRED")
				return
			var expected := _offender()
			if d.get("offender") != expected: _stop_conflict("RECOVERY_CONFLICT")
			elif int(d.disposition) != (3 if expected < 0 else (0 if store.state.round_status == "OPEN" else 1)): _stop_conflict("RECOVERY_CONFLICT")
			else: _send(36, {"base_hash": store.state.last_hash, "recovery_id": d.recovery_id, "remaining": recovery.remaining_ms() if local_continuous else int(d.remaining)}, 3)
		36:
			if not host or not resuming or d.get("base_hash") != store.state.last_hash: return
			var old_epoch: int = int(recovery.observation.get("old_epoch", remote_resume.get("old_epoch", 0)))
			if d.recovery_id != DuelIds.recovery_id(store.state.match_id, old_epoch).hex_encode(): return
			if local_continuous and recovery.remaining_ms() <= 0: _stop_conflict("RECOVERY_EXPIRED")
			else: _commit_recovery(d)
		37:
			if host or not d.get("checkpoint") is PackedByteArray: return
			if d.seq != store.state.last_seq or d.hash != store.state.last_hash: return
			var saved := store.save_checkpoint(d.checkpoint)
			if not saved.ok: _stop_conflict(saved.error_code)
			else:
				store.files._fault("before_checkpoint_ack")
				pending_checkpoint_hash = d.checkpointHash
				_send(31, {"ackKind": 1, "seq": store.state.last_seq, "hash": store.state.last_hash, "epoch": epoch, "checkpointHash": pending_checkpoint_hash}, 3)
		39:
			if host or d.get("seq") != store.state.last_seq or d.get("hash") != store.state.last_hash: return
			if d.checkpointHash != pending_checkpoint_hash: return
			var result := store.confirm_checkpoint(d.seq, d.hash)
			if not result.ok: _stop_conflict(result.error_code)
		40:
			rematch_ready[1 - local_slot] = d.get("ready", false)
			phase_changed.emit()
			if host and rematch_ready == [true, true]: _new_rematch()
		41:
			if d.old_epoch != epoch: return
			graceful_slot = 1 - local_slot
			_lost()
		43:
			if d.oldEpoch != _old_epoch(): return
			if not terminal_status.is_empty():
				var reply := terminal_status.duplicate(true)
				reply.requestId = d.requestId
				_send(44, reply, 0)
		44:
			if d.requestId != status_request_id or d.oldEpoch != _old_epoch(): return
			var notice := d.duplicate(true)
			notice.erase("requestId")
			if not store.validate_terminal_notice(notice):
				_stop_conflict("HISTORY_FORK")
				return
			if notice.resultStatus == 1 and notice.offender != _offender(): return
			if not terminal_status.is_empty() and (terminal_status.resultStatus != notice.resultStatus or terminal_status.winner != notice.winner):
				_stop_conflict("RECOVERY_CONFLICT")
				return
			var saved := store.persist_terminal_notice(notice, host, epoch)
			if not saved.ok:
				_stop_conflict("STORE_WRITE_FAILED")
				return
			terminal_status = notice
			if not profile.record_closed(store.state.match_id, notice.resumeBlock, notice.resultStatus).ok:
				_stop_conflict("STORE_WRITE_FAILED")
				return
			recovery.expired = notice.timerStatus == 2
			recovery.conflict = true
			diagnostic_only = true
			phase = CanonicalCodec.Phase.CONFLICT
			_send(45, {"noticeId": notice.noticeId, "oldEpoch": notice.oldEpoch}, 0)
			_set_status(RecoveryStatus.message(notice) + " 相手の終了通知を保存しました。")
			phase_changed.emit()
		45:
			if not terminal_status.is_empty() and d.noticeId == terminal_status.noticeId and d.oldEpoch == terminal_status.oldEpoch:
				_set_status(RecoveryStatus.message(terminal_status) + " 相手への通知が確認できました。")
		42:
			if host or not d.get("code") is String: return
			var code: String = d.code
			transport.close()
			peers.clear()
			active_peer = null
			connected = false
			store = RecoveryStore.new()
			recovery = RecoveryCoordinator.new()
			recovery.clock = clock
			recovery.store = store
			director = RoundDirector.new()
			director.config = config
			resuming = false
			rematch_ready = [false, false]
			join_room(code)
		50:
			if host:
				if d.round == store.state.round and d.requestId > last_spawn_request:
					last_spawn_request = d.requestId
					choose_spawn(1, d.spawn, d.revision)
				else: _send_phase_only()

func _create_match() -> void:
	_commit(MatchEvent.make(1, {"match_id": str(invitation_data.match).hex_decode(), "rule_hash": config.rules_hash, "map_hash": config.map_hash,
		"players": [{"id": profile.player_id, "slot": 0}, {"id": session_data.guest_id, "slot": 1}], "epoch": epoch}), "prepare")

func _commit(event: MatchEvent, next: String) -> void:
	var r := store.append_transaction([event])
	if not r.ok:
		_stop_conflict(r.error_code)
		return
	awaiting = next
	awaited_seq = store.state.last_seq
	_send(30, {"record": store.records.back()}, 3)

func _after_ack(next: String) -> void:
	match next:
		"prepare":
			if store.state.is_terminal():
				var indexed := profile.record_closed(store.state.match_id, 1, 1 if store.state.terminal_reason == "DISCONNECT_TIMEOUT" else (2 if store.state.match_winner < 0 else 3))
				if not indexed.ok:
					_stop_conflict("STORE_WRITE_FAILED")
					return
				phase = CanonicalCodec.Phase.MATCH_RESULT
				phase_changed.emit()
				return
			if store.checkpoint_due():
				var bytes := DuelCheckpoint.encode(store.state)
				var saved := store.save_checkpoint(bytes)
				if not saved.ok:
					_stop_conflict(saved.error_code)
					return
				awaiting = "checkpoint"
				awaited_seq = store.state.last_seq
				pending_checkpoint_hash = DuelIds.digest(bytes)
				_send(37, {"checkpoint": bytes}, 3)
				return
			_commit(director.begin_round(store.state, int(DuelIds.random_bytes(4).decode_u32(0))), "activate")
		"checkpoint":
			var saved := store.confirm_checkpoint(store.state.last_seq, store.state.last_hash)
			if not saved.ok:
				_stop_conflict(saved.error_code)
				return
			_send(39, {"seq": store.state.last_seq, "hash": store.state.last_hash, "checkpointHash": pending_checkpoint_hash}, 3)
			_after_ack("prepare")
		"activate":
			store.files._fault("before_round_activate")
			_commit(MatchEvent.make(3, {"round": store.state.prepared_round}), "select")
			store.files._fault("after_round_activate")
		"select":
			action_ledger.reset(store.state.round)
			pending_actions.clear()
			active_swap.clear()
			director.activate(tick)
			baseline_ready = false
			phase = director.phase
			_publish_phase()
		"recovered":
			if diagnostic_only: return
			_finish_resume()
			_after_ack("prepare")

func _publish_phase() -> void:
	var data := director.to_data()
	data.round = store.state.round
	data.tick = tick
	_send(23, data, 0)
	phase_changed.emit()
	if phase == CanonicalCodec.Phase.COUNTDOWN:
		world.simulation.reset_round(store.state.round, director.selected_spawn, int(DuelIds.random_bytes(4).decode_u32(0)))
		world.sync_items()
		_send_baseline()

func _send_baseline() -> void:
	if journal.round_number != store.state.round:
		journal.reset(store.state.round)
		baseline_id = 0
		baseline_request_id = 0
	baseline_id += 1
	var data := EntityWire.baseline(world.simulation, tick, baseline_id, journal.sequence)
	if not data.ok:
		_stop_conflict(data.error_code)
		return
	cached_baseline = data.value
	baseline_hash = cached_baseline.hash
	journal.observe(world.simulation)
	_send(24, cached_baseline, 3)
	world_received.emit(Replication.world_data(world.simulation, tick))

func _present_replica() -> void:
	if replica.conflict:
		_stop_conflict("PROTOCOL_CONFLICT")
		return
	if not replica.notifications.is_empty():
		game_events.emit(replica.notifications)
		replica.notifications.clear()
	world.sync_items()

func choose_spawn(slot: int, spawn: int, revision: int = -1) -> void:
	if not host:
		spawn_request_id += 1
		_send(50, {"round": store.state.round, "requestId": spawn_request_id, "spawn": spawn, "revision": director.revision}, 0)
		return
	var result := director.accept_spawn(slot, spawn, director.revision if revision < 0 else revision, tick)
	if result.ok:
		phase = director.phase
		_publish_phase()
	else: _send_phase_only()

func _send_phase_only() -> void:
	var data := director.to_data()
	data.round = store.state.round
	data.tick = tick
	_send(23, data, 0)

func physics(frame: InputFrame) -> void:
	tick += 1
	if store.state.is_terminal(): return
	if not connected or recovery.suspended or phase in [CanonicalCodec.Phase.CONFLICT, CanonicalCodec.Phase.STORAGE_ERROR]: return
	if host:
		if not awaiting.is_empty(): return
		if phase == CanonicalCodec.Phase.COUNTDOWN and tick >= director.deadline_tick and not baseline_ready:
			_lost()
			return
		if not director.step(tick).is_empty():
			phase = director.phase
			_publish_phase()
		if phase != CanonicalCodec.Phase.FIGHTING: return
		var remote := remote_input
		if Time.get_ticks_msec() - remote_input_ms >= 100: remote = remote_input.neutral()
		remote = _action_frame(remote)
		var accepted: Dictionary = {}
		if not pending_actions.is_empty():
			var ready: Array = []
			for request in pending_actions.duplicate():
				if abs(request.sampleTick - tick) > 12:
					_complete_action(request.actionId, 9)
					pending_actions.erase(request)
				elif request.inputSeq <= remote.seq:
					ready.append(request)
					pending_actions.erase(request)
			ready.sort_custom(func(x, y): return ActionCommands.priority(x) < ActionCommands.priority(y) if ActionCommands.priority(x) != ActionCommands.priority(y) else x.actionId < y.actionId)
			if not ready.is_empty(): accepted = ready.pop_front()
			for rejected in ready: _complete_action(rejected.actionId, 8)
		if not accepted.is_empty():
			action_ledger.pending[accepted.actionId] = tick
			var code := ActionCommands.preflight(accepted, world.simulation.players[1], world.simulation, tick)
			if code != 0:
				_complete_action(accepted.actionId, code)
				accepted = {}
			else: remote.actions = [ActionCommands.command(accepted)]
		var events := world.simulation.step([frame, remote], tick)
		if not accepted.is_empty():
			if accepted.actionType == 5 and world.simulation.players[1].action == CanonicalCodec.Action.SWAP:
				active_swap = accepted
				active_swap.weapon_id = world.simulation.pickup.target(world.simulation.players[1]).get("weapon", {}).get("id", 0)
			else:
				var result_code := 0
				for event in events:
					if event.kind == "action_rejected" and event.slot == 1: result_code = 3
				_complete_action(accepted.actionId, result_code)
		if not active_swap.is_empty() and world.simulation.players[1].action != CanonicalCodec.Action.SWAP:
			_complete_action(active_swap.actionId, 0 if world.simulation.players[1].inventory.active().get("id", 0) == active_swap.weapon_id else 8)
			active_swap = {}
		game_events.emit(events)
		var wire_events := journal.collect(world.simulation, events)
		world.simulation.pickup.items = world.simulation.pickup.items.filter(func(item): return item.amount > 0)
		var batches := EventJournal.batches(wire_events)
		if not batches.ok or journal.sequence > 0x7fffffffffffffff - wire_events.size():
			_stop_conflict("EVENT_ENCODING_LIMIT")
			return
		for batch in batches.value:
			_send(22, {"round": store.state.round, "firstEventSeq": journal.sequence + 1, "serverTick": tick, "events": batch}, 3)
			journal.sequence += batch.size()
		if tick % 3 == 0:
			_send(11, {"round": store.state.round, "tick": tick, "players": [Replication.player_data(world.simulation.players[0]), Replication.player_data(world.simulation.players[1])]}, 2, false)
		if tick % 6 == 0:
			var entities: Array = []
			for kind in [1, 2]:
				for entity in world.simulation.weapons.projectiles if kind == 1 else world.simulation.grenade.grenades:
					entities.append({"kind": kind, "id": entity.id, "position": SnapshotCodec.vector(entity.position), "velocity": SnapshotCodec.vector(entity.velocity)})
			while not entities.is_empty():
				var batch := entities.slice(0, 24)
				entities = entities.slice(batch.size())
				_send(12, {"round": store.state.round, "tick": tick, "requiredEventSeq": journal.sequence, "entities": batch}, 2, false)
		var winner := MatchReducer.decide_round(world.simulation.players, tick >= director.deadline_tick)
		if winner != -2:
			_send_baseline()
			phase = CanonicalCodec.Phase.RESOLVING
			director.phase = phase
			_commit(MatchEvent.make(4, {"round": store.state.round, "winner": winner, "reason": 2 if tick >= director.deadline_tick else (1 if winner == -1 else 0), "closed_tick": tick}), "prepare")
			phase_changed.emit()
	else:
		world.simulation.tick = tick
		replica.visual_step(world.simulation, tick)
		replica.maintain(world.simulation, Time.get_ticks_msec())
		if prediction.needs_baseline: baseline_requester.request(4)
		if replica.request_reason > 0: baseline_requester.request(replica.request_reason)
		var baseline_request := baseline_requester.poll(store.state.round, replica.sequence, tick, Time.get_ticks_msec()) if phase in [1, 4, 5, 6] else {}
		if not baseline_request.is_empty(): _send(26, baseline_request, 3)
		if baseline_requester.failed:
			_stop_conflict("RESYNC_UNAVAILABLE")
			return
		if not pending_snapshot.is_empty():
			last_snapshot_tick = pending_snapshot.tick
			tick = last_snapshot_tick + int(round(rtt_ms * 0.03))
			Replication.apply_player(world.simulation.players[0], pending_snapshot.players[0])
			var other: PlayerState = world.simulation.players[0]
			world.remote_interpolation.push(last_snapshot_tick, other.position, other.velocity, other.yaw, Time.get_ticks_msec())
			prediction.reconcile(world.simulation.players[1], pending_snapshot.players[1], world.simulation.movement)
			pending_snapshot = {}
		if phase != CanonicalCodec.Phase.FIGHTING or not baseline_ready or baseline_requester.active: return
		frame.sample_tick = tick
		if input_round != store.state.round:
			input_round = store.state.round
			recent_inputs.clear()
			local_actions.clear()
		for action in frame.actions:
			if local_actions.size() >= 16: break
			var type: int = ActionCommands.KINDS.find(action.kind)
			if type < 0: continue
			next_action_id += 1
			var target := world.simulation.pickup.target(world.simulation.players[1]) if type == 5 else {}
			var argument := int(action.get("argument", 0))
			if type == 3 and argument == 0: argument = world.simulation.players[1].inventory.selected_heal
			var request := {"round": store.state.round, "actionId": next_action_id, "inputSeq": frame.seq, "sampleTick": tick, "actionType": type,
				"targetId": int(target.get("id", 0)), "expectedRevision": int(target.get("revision", 0)), "argument": argument}
			local_actions[next_action_id] = request
			last_sent_action_request = request.duplicate(true)
			_send(20, request, 3, true)
		recent_inputs.append({"seq": frame.seq, "sampleTick": frame.sample_tick, "axisX": int(round(clampf(frame.axes.x, -1, 1) * 32767)), "axisY": int(round(clampf(frame.axes.y, -1, 1) * 32767)), "yaw": wrapf(frame.yaw, -PI, PI), "pitch": frame.pitch, "held": frame.held_buttons})
		if recent_inputs.size() > 3: recent_inputs.pop_front()
		_send(10, {"round": store.state.round, "samples": recent_inputs}, 1, false)
		prediction.predict(world.simulation.players[1], frame, world.simulation.movement)

func _action_frame(source: InputFrame) -> InputFrame:
	var copy := InputFrame.new()
	copy.reliable_edges = true
	copy.seq = source.seq
	copy.sample_tick = source.sample_tick
	copy.axes = source.axes
	copy.yaw = source.yaw
	copy.pitch = source.pitch
	copy.held_buttons = source.held_buttons
	return copy

func _complete_action(id: int, code: int) -> void:
	if action_ledger.pending.has(id) and (active_swap.is_empty() or active_swap.actionId != id): action_ledger.pending[id] = tick
	var result := action_ledger.complete(id, code, world.simulation.players[1].inventory.revision, tick)
	if result.ok: _send(21, result.value, 3)

func _lost() -> void:
	if diagnostic_only:
		connected = false
		active_peer = null
		if not host: transport.close()
		return
	if OS.is_debug_build(): print(JSON.stringify({"link_lost": true, "silent_ms": Time.get_ticks_msec() - last_receive_ms}))
	if not connected and resuming: return
	old_connection_epoch = int(session_data.epoch)
	connected = false
	phase = CanonicalCodec.Phase.SUSPENDED
	resuming = true
	if not recovery.suspended:
		var r := recovery.on_link_lost(2 if graceful_slot >= 0 else 1, int(session_data.epoch), profile.boot_id, session_data.guest_boot if host else session_data.host_boot)
		if not r.ok: _stop_conflict(r.error_code)
	if active_peer != null and active_peer.is_active(): active_peer.peer_disconnect_now()
	active_peer = null
	peers.clear()
	if not host: transport.close()
	_set_status("接続が切れました。最大60秒間、認証と履歴の復元を待ちます。")
	phase_changed.emit()

func _begin_resume() -> void:
	resuming = true
	recovery.suspended = true
	phase = CanonicalCodec.Phase.SUSPENDED
	_send(32, _resume_data(), 3)
	if diagnostic_only:
		phase = CanonicalCodec.Phase.CONFLICT
		_request_status()

func _old_epoch() -> int:
	return int(terminal_status.get("oldEpoch", recovery.observation.get("old_epoch", old_connection_epoch if old_connection_epoch > 0 else remote_resume.get("old_epoch", session_data.get("epoch", 1)))))

func _request_status() -> void:
	if status_request_id.is_empty(): status_request_id = DuelIds.random_bytes(16)
	var hash_value := store.state.last_hash.duplicate()
	if hash_value.is_empty(): hash_value.resize(32)
	_send(43, {"requestId": status_request_id, "oldEpoch": _old_epoch(), "seq": store.state.last_seq, "hash": hash_value}, 0)

func check_status() -> void:
	diagnostic_only = true
	diagnostic_until_ms = Time.get_ticks_msec() + 30000
	status_request_id = DuelIds.random_bytes(16)
	started = true
	resuming = true
	phase = CanonicalCodec.Phase.CONFLICT
	_set_status("保存した相手へ状態を確認しています…（最大30秒）")
	if connected: _request_status()
	else:
		transport.close()
		peers.clear()
		if host: transport.listen(invitation_data)
		else: transport.connect_to(invitation_data)

func _resume_data() -> Dictionary:
	return {"seq": store.state.last_seq, "hash": store.state.last_hash, "boot": profile.boot_id,
		"old_host_boot": session_data.host_boot, "old_guest_boot": session_data.guest_boot, "old_epoch": _old_epoch(),
		"remaining": recovery.remaining_ms() if local_continuous else 0xffffffff, "continuous": local_continuous and not clock.is_uncertain(), "terminal": diagnostic_only,
		"timer_status": terminal_status.get("timerStatus", 3 if clock.is_uncertain() else (1 if local_continuous else 0)),
		"resume_block": terminal_status.get("resumeBlock", 0), "evidence": terminal_status.get("evidence", 1 if local_continuous else 0)}

func _offender() -> int:
	if terminal_status.get("resultStatus", 0) == 1 and store.validate_terminal_notice(terminal_status): return terminal_status.offender
	if graceful_slot in [0, 1] and local_continuous and clock != null and not clock.is_uncertain(): return graceful_slot
	if remote_resume.is_empty() or profile == null or not session_data.has_all(["host_boot", "guest_boot"]): return -1
	var host_boot: PackedByteArray = profile.boot_id if host else remote_resume.get("boot", PackedByteArray())
	var guest_boot: PackedByteArray = remote_resume.get("boot", PackedByteArray()) if host else profile.boot_id
	var continuous := local_slot if local_continuous else (1 - local_slot if remote_resume.get("continuous", false) else -1)
	return RecoveryCoordinator.identify_offender(host_boot != session_data.host_boot, guest_boot != session_data.guest_boot, continuous, graceful_slot)

func _reconcile() -> void:
	if remote_resume.is_empty(): return
	if remote_resume.get("terminal", true) or (local_continuous and recovery.remaining_ms() <= 0):
		_stop_conflict("RECOVERY_EXPIRED")
		return
	var seq: int = remote_resume.get("seq", -1)
	if seq < 0: return
	if seq > store.state.last_seq:
		_send(33, {"from": store.state.last_seq + 1}, 3)
		return
	if seq < store.state.last_seq:
		var prefix: PackedByteArray = store.hash_at(seq)
		if prefix != remote_resume.get("hash"): _stop_conflict("HISTORY_FORK")
		else:
			var history := store.history_after(seq)
			if not history.ok:
				_stop_conflict(history.error_code)
				return
			for record in history.value: _send(34, {"record": record}, 3)
			_send(34, {"done": true, "seq": store.state.last_seq, "hash": store.state.last_hash}, 3)
		return
	if remote_resume.get("hash") != store.state.last_hash:
		_stop_conflict("HISTORY_FORK")
		return
	var offender := _offender()
	var old_epoch: int = int(recovery.observation.get("old_epoch", remote_resume.get("old_epoch", 0)))
	_send(35, {"base_hash": store.state.last_hash, "offender": offender, "recovery_id": DuelIds.recovery_id(store.state.match_id, old_epoch).hex_encode(),
		"old_epoch": old_epoch, "new_epoch": epoch, "round": store.state.round, "disposition": 3 if offender < 0 else (0 if store.state.round_status == "OPEN" else 1),
		"remaining": recovery.remaining_ms() if local_continuous else (int(remote_resume.remaining) if remote_resume.continuous else 0)}, 3)

func _commit_recovery(d: Dictionary) -> void:
	var old_epoch: int = int(recovery.observation.get("old_epoch", remote_resume.get("old_epoch", 0)))
	var event := MatchEvent.make(5, {"round": store.state.round, "old_epoch": old_epoch, "new_epoch": epoch, "recovery_id": d.recovery_id,
		"offender": _offender(), "disposition": 3 if _offender() < 0 else (0 if store.state.round_status == "OPEN" else 1)})
	store.files._fault("before_recovery_commit")
	_commit(event, "recovered")
	store.files._fault("after_recovery_commit")

func _finish_resume() -> void:
	var pruned := store.prune_observations()
	if not pruned.ok:
		_stop_conflict(pruned.error_code)
		return
	var info: Dictionary = peers[active_peer]
	session_data.host_boot = profile.boot_id if host else info.host_boot
	session_data.guest_boot = info.guest_boot if host else profile.boot_id
	session_data.epoch = epoch
	if not _save_session().ok:
		_stop_conflict("STORE_WRITE_FAILED")
		return
	resuming = false
	diagnostic_until_ms = 0
	local_continuous = true
	recovery = RecoveryCoordinator.new()
	recovery.clock = clock
	recovery.store = store
	remote_resume = {}
	_set_status("勝者なし・得点不変で試合を中断しました。" if store.state.terminal_reason == "RESPONSIBILITY_UNKNOWN" else "復帰が完了しました。")

func _stop_conflict(reason: String) -> void:
	# An already committed receipt is never replaced by a second timeout outcome.
	if reason == "RECOVERY_EXPIRED" and store.state.last_recovery_epoch == _old_epoch() and store.state.last_recovery_epoch > 0:
		reason = "RECOVERY_ACK_TIMEOUT"
	recovery.conflict = true
	if reason in ["RECOVERY_EXPIRED", "RECOVERY_ACK_TIMEOUT"]:
		recovery.expired = true
	var boot := profile.boot_id if profile != null else DuelIds.random_bytes(16)
	if terminal_status.get("resultStatus", 0) in [1, 2, 3] and store.validate_terminal_notice(terminal_status):
		terminal_status = terminal_status.duplicate(true)
		if reason.begins_with("STORE"): terminal_status.resumeBlock = 4
		elif reason == "CLOCK_UNCERTAIN": terminal_status.resumeBlock = 6
		elif reason in ["HISTORY_FORK", "RECOVERY_CONFLICT"]: terminal_status.resumeBlock = 3
	else:
		terminal_status = RecoveryStatus.create(store.state, maxi(1, _old_epoch()), boot, recovery.observation, reason, _offender())
	var saved := store.persist_terminal_notice(terminal_status, host, epoch)
	if not saved.ok: reason = "STORE_WRITE_FAILED"
	if saved.ok and profile != null and store.state.match_id.size() == 16:
		if not profile.record_closed(store.state.match_id, terminal_status.resumeBlock, terminal_status.resultStatus).ok: reason = "STORE_WRITE_FAILED"
	diagnostic_only = true
	if diagnostic_until_ms == 0: diagnostic_until_ms = Time.get_ticks_msec() + 30000
	phase = CanonicalCodec.Phase.STORAGE_ERROR if reason.begins_with("STORE") else CanonicalCodec.Phase.CONFLICT
	_set_status(RecoveryStatus.message(terminal_status) + " " + reason)
	if reason == "RECOVERY_ACK_TIMEOUT":
		_set_status("復帰記録は保存済みですが、期限内の最終確認を完了できませんでした。得点を保持して状態を確認します。")
	if reason == "RECOVERY_EXPIRED" and _offender() < 0:
		_set_status("復帰期限が過ぎたため、勝者なし・得点不変で試合を中断しました。相手との終了合意は未確認です。")
	phase_changed.emit()

func rematch() -> void:
	rematch_ready[local_slot] = true
	_send(40, {"ready": true})
	if host and rematch_ready == [true, true]: _new_rematch()

func _new_rematch() -> void:
	var address: String = invitation_data.host
	var port: int = invitation_data.port
	var data := {"v": 2, "match": DuelIds.random_bytes(16).hex_encode(), "host": address, "port": port,
		"secret": DuelIds.random_bytes(32).hex_encode(), "rules": config.rules_hash.hex_encode(), "map": config.map_hash.hex_encode()}
	_send(42, {"code": DuelAuth.invitation(data)}, 0)
	# Keep the existing transport alive until ENet drains the reliable invitation.
	if active_peer != null: active_peer.peer_disconnect_later()
	invitation_data = data
	store = RecoveryStore.new()
	store.initialize(profile, str(data.match).hex_decode())
	session_data = {"invitation": data, "host": true, "host_id": profile.player_id, "guest_id": PackedByteArray(), "host_boot": profile.boot_id, "guest_boot": PackedByteArray(), "epoch": 0}
	_save_session()
	connected = false
	active_peer = null
	peers.clear()
	epoch = 0
	resuming = false
	rematch_ready = [false, false]
	lobby_ready = [false, false]
	director = RoundDirector.new()
	director.config = config
	phase = CanonicalCodec.Phase.LOBBY
	_set_status("再戦の接続を待っています…")

func close() -> void:
	if connected: _send(41, {"reason": 2, "old_epoch": epoch})
	transport.close()
	started = false
	connected = false

func _set_status(message: String) -> void:
	if status == message: return
	status = message
	status_changed.emit(message)
