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
var last_receive_ms: int = 0
var last_heartbeat_ms: int = 0
var connect_started_ms: int = 0
var last_retry_ms: int = 0
var awaiting: String = ""
var awaited_seq: int = 0
var baseline_ready: bool = false
var baseline_hash: PackedByteArray
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

func setup(cfg: GameConfig, user: DuelProfile, game_clock: DuelClock, view: WorldView) -> void:
	config = cfg
	profile = user
	clock = game_clock
	world = view
	director.config = cfg
	recovery.clock = clock
	recovery.store = store

func create_room(address: String = "127.0.0.1", port: int = 27840) -> DuelResult:
	host = true
	local_slot = 0
	world.local_slot = 0
	invitation_data = {"v": 1, "match": DuelIds.random_bytes(16).hex_encode(), "host": address, "port": port,
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
	store.initialize(profile, str(invitation_data.match).hex_decode())
	session_data = {"invitation": invitation_data, "host": false, "host_id": PackedByteArray(), "guest_id": profile.player_id,
		"host_boot": PackedByteArray(), "guest_boot": profile.boot_id, "epoch": 0}
	connect_started_ms = Time.get_ticks_msec()
	started = true
	_set_status("接続しています…")
	return transport.connect_to(invitation_data)

func restore() -> DuelResult:
	var current := profile.files.load_ab(profile.root + "/current-match.json")
	if not current.ok: return current
	var mid: PackedByteArray = current.value.value
	store.initialize(profile, mid)
	var saved := store.files.load_ab(store.root + "/session.json")
	if not saved.ok: return saved
	session_data = saved.value.value
	invitation_data = session_data.invitation
	if invitation_data.rules != config.rules_hash.hex_encode(): return DuelResult.failure("VERSION_MISMATCH")
	var terminal := store.files.load_ab(store.root + "/terminal.json")
	if terminal.ok or terminal.error_code != "NOT_FOUND": return DuelResult.failure("TERMINAL")
	var history := store.load_match(mid)
	if not history.ok: return history
	if store.state.is_terminal(): return DuelResult.failure("TERMINAL")
	host = session_data.host
	local_slot = 0 if host else 1
	world.local_slot = local_slot
	epoch = int(session_data.epoch)
	resuming = true
	local_continuous = false
	recovery.suspended = true
	phase = CanonicalCodec.Phase.SUSPENDED
	started = true
	connect_started_ms = Time.get_ticks_msec()
	_set_status("保存した接続先へ復帰しています…")
	return transport.listen(invitation_data) if host else transport.connect_to(invitation_data)

func _save_session() -> DuelResult:
	var saved := store.files.save_ab(store.root + "/session.json", session_data)
	if not saved.ok: return saved
	return profile.files.save_ab(profile.root + "/current-match.json", str(invitation_data.match).hex_decode())

func poll() -> void:
	if not started: return
	var now := Time.get_ticks_msec()
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
	elif not host and resuming and now - last_retry_ms >= 500 and not recovery.expired and not recovery.conflict:
		last_retry_ms = now
		if peers.is_empty(): transport.connect_to(invitation_data)
	elif not host and not resuming and now - connect_started_ms >= 8000:
		_set_status("接続できません。IP・ファイアウォールを確認するか補助ネットワークを利用してください。")
		transport.close()
		started = false
	if recovery.suspended and local_continuous:
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
	var data := SnapshotCodec.decode(packet.payload) if packet.kind == 11 else CanonicalCodec.decode(packet.payload)
	if not data.ok or not data.value is Dictionary:
		if OS.is_debug_build(): print(JSON.stringify({"payload_rejected": data.error_code, "kind": packet.kind, "bytes": packet.payload.size()}))
		return
	if not info.auth:
		# ENet orders each channel independently. A session-key-authenticated
		# record on channel 3 can overtake Authenticated on channel 0.
		if not host and info.stage == 1 and packet.kind not in [2, 4]:
			if packet.epoch == epoch and packet.slot == 0 and info.early.size() < 16 and info.early_bytes + packet.payload.size() <= 32768:
				info.early.append({"kind": packet.kind, "data": data.value})
				info.early_bytes += packet.payload.size()
			return
		_handshake(peer, packet.kind, data.value, packet.epoch)
		return
	if peer != active_peer or packet.slot != 1 - local_slot: return
	last_receive_ms = now
	_dispatch(packet.kind, data.value)

func _bytes(d: Dictionary, name: String, size: int) -> bool:
	return d.has(name) and d[name] is PackedByteArray and d[name].size() == size

func _handshake(peer: ENetPacketPeer, kind: int, d: Dictionary, packet_epoch: int) -> void:
	var info: Dictionary = peers[peer]
	if host and kind == 1 and info.stage == 0:
		if not _bytes(d, "player", 16) or not _bytes(d, "boot", 16) or not _bytes(d, "nonce", 32) or d.get("rules") != config.rules_hash or d.get("map") != config.map_hash: return
		if not session_data.guest_id.is_empty() and d.player != session_data.guest_id: return
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
		else: _create_match()
	elif not host and kind == 4 and info.stage == 1:
		if d.get("guest") != profile.player_id or d.get("epoch") != epoch: return
		if not _bind(peer): return
		if resuming: _begin_resume()
		var early: Array = info.early
		info.early = []
		info.early_bytes = 0
		for message in early: _dispatch(message.kind, message.data)

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
	var info: Dictionary = peers[peer]
	var payload := SnapshotCodec.encode(data) if kind == 11 else CanonicalCodec.encode(data)
	for bytes in info.codec.encode(kind, payload, str(invitation_data.match).hex_decode(), epoch if forced_epoch < 0 else forced_epoch, local_slot, channel, info.key):
		var result := transport.send(peer, channel, bytes, reliable)
		if result.ok: sent_bytes += bytes.size()

func _send(kind: int, data: Dictionary, channel: int = 0, reliable: bool = true) -> void:
	if active_peer != null: _send_to(active_peer, kind, data, channel, reliable)

func _dispatch(kind: int, d: Dictionary) -> void:
	match kind:
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
			if not host or phase != CanonicalCodec.Phase.FIGHTING: return
			var r := Replication.parse_input(d, store.state.round)
			if r.ok and r.value.seq > last_action_seq:
				last_action_seq = r.value.seq
				pending_actions.append_array(r.value.actions)
		11:
			if host or not d.has("players") or d.get("round") != store.state.round or int(d.get("tick", -1)) <= maxi(last_snapshot_tick, int(pending_snapshot.get("tick", -1))): return
			pending_snapshot = d
		22:
			if not host and d.get("round") == store.state.round and d.get("events") is Array: game_events.emit(d.events)
		23:
			if host or not d.has("phase") or not d.has("revision") or d.get("round") != store.state.round: return
			if d.revision <= director.revision: return
			director.phase = d.phase
			director.revision = d.revision
			director.deadline_tick = d.deadline_tick
			director.first_slot = d.first_slot
			director.selected_spawn = d.selected_spawn
			tick = int(d.get("tick", tick))
			phase = d.phase
			phase_changed.emit()
		24:
			if host or d.get("round") != store.state.round: return
			if d.has("world"):
				var initialize_camera := not baseline_ready or world.simulation.round_number != int(d.world.round)
				if initialize_camera: world.remote_interpolation.clear()
				Replication.apply_world(world.simulation, d.world)
				if initialize_camera: tick = int(d.world.tick)
				world.sync_items()
				baseline_ready = true
				baseline_hash = DuelIds.digest(CanonicalCodec.encode(d.world))
				if initialize_camera: _send(25, {"round": store.state.round, "hash": baseline_hash}, 3)
				if initialize_camera: world_received.emit(d.world)
		25:
			if host and d.get("round") == store.state.round and d.get("hash") == baseline_hash: baseline_ready = true
		30:
			if host or not d.get("record") is PackedByteArray: return
			var previous_round := store.state.round
			var r := store.append_raw(d.record)
			if not r.ok:
				_stop_conflict(r.error_code)
				return
			if store.state.round != previous_round:
				director.revision = 0
				last_snapshot_tick = -1
				prediction.frames.clear()
				baseline_ready = false
			store.files._fault("before_ack")
			_send(31, {"seq": store.state.last_seq, "hash": store.state.last_hash, "epoch": epoch}, 3)
			store.files._fault("after_ack")
			if resuming and store.state.last_recovery_epoch > 0:
				if local_continuous and (recovery.remaining_ms() <= 0 or clock.is_uncertain()): _stop_conflict("RECOVERY_EXPIRED")
				else: _finish_resume()
			if store.state.is_terminal():
				phase = CanonicalCodec.Phase.MATCH_RESULT
				phase_changed.emit()
		31:
			if not host or d.get("epoch") != epoch or d.get("seq") != awaited_seq or d.get("hash") != store.state.last_hash: return
			var next := awaiting
			awaiting = ""
			_after_ack(next)
		32:
			if not resuming: return
			remote_resume = d
			if d.get("terminal", false):
				_stop_conflict("RECOVERY_EXPIRED")
				return
			if host: _reconcile()
		33:
			if not d.get("from") is int: return
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
			if local_continuous and (recovery.remaining_ms() <= 0 or clock.is_uncertain()):
				_stop_conflict("RECOVERY_EXPIRED")
				return
			var expected := _offender()
			if expected < 0 or d.get("offender") != expected: _stop_conflict("D08_UNAPPROVED")
			else: _send(36, {"base_hash": store.state.last_hash, "recovery_id": d.recovery_id, "offender": expected}, 3)
		36:
			if not host or not resuming or d.get("base_hash") != store.state.last_hash: return
			if local_continuous and recovery.remaining_ms() <= 0: _stop_conflict("RECOVERY_EXPIRED")
			else: _commit_recovery(d)
		37:
			if host or not d.get("checkpoint") is PackedByteArray: return
			var saved := store.save_checkpoint(d.checkpoint)
			if not saved.ok: _stop_conflict(saved.error_code)
			else:
				store.files._fault("before_checkpoint_ack")
				_send(31, {"seq": store.state.last_seq, "hash": store.state.last_hash, "epoch": epoch}, 3)
		39:
			if host or d.get("seq") != store.state.last_seq or d.get("hash") != store.state.last_hash: return
			var result := store.confirm_checkpoint(d.seq, d.hash)
			if not result.ok: _stop_conflict(result.error_code)
		40:
			rematch_ready[1 - local_slot] = d.get("ready", false)
			phase_changed.emit()
			if host and rematch_ready == [true, true]: _new_rematch()
		41: _lost()
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
			if host and d.get("round") == store.state.round and d.get("spawn") is int: choose_spawn(1, d.spawn, int(d.get("revision", -1)))

func _create_match() -> void:
	_commit(MatchEvent.make(1, {"match_id": str(invitation_data.match).hex_decode(), "rule_hash": config.rules_hash,
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
				phase = CanonicalCodec.Phase.MATCH_RESULT
				phase_changed.emit()
				return
			if store.state.round > 0 and store.state.round % 128 == 0 and store.checkpoint_seq != store.state.last_seq:
				var bytes := DuelCheckpoint.encode(store.state)
				var saved := store.save_checkpoint(bytes)
				if not saved.ok:
					_stop_conflict(saved.error_code)
					return
				awaiting = "checkpoint"
				awaited_seq = store.state.last_seq
				_send(37, {"checkpoint": bytes}, 3)
				return
			_commit(director.begin_round(store.state, int(DuelIds.random_bytes(4).decode_u32(0))), "activate")
		"checkpoint":
			var saved := store.confirm_checkpoint(store.state.last_seq, store.state.last_hash)
			if not saved.ok:
				_stop_conflict(saved.error_code)
				return
			_send(39, {"seq": store.state.last_seq, "hash": store.state.last_hash}, 3)
			_after_ack("prepare")
		"activate":
			store.files._fault("before_round_activate")
			_commit(MatchEvent.make(3, {"round": store.state.prepared_round}), "select")
			store.files._fault("after_round_activate")
		"select":
			director.activate(tick)
			baseline_ready = false
			phase = director.phase
			_publish_phase()
		"recovered":
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
	var data := Replication.world_data(world.simulation, tick)
	baseline_hash = DuelIds.digest(CanonicalCodec.encode(data))
	_send(24, {"round": store.state.round, "world": data}, 3)
	world_received.emit(data)

func choose_spawn(slot: int, spawn: int, revision: int = -1) -> void:
	if not host:
		_send(50, {"round": store.state.round, "spawn": spawn, "revision": director.revision}, 0)
		return
	var result := director.accept_spawn(slot, spawn, director.revision if revision < 0 else revision, tick)
	if result.ok:
		phase = director.phase
		_publish_phase()

func physics(frame: InputFrame) -> void:
	tick += 1
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
		remote.actions = pending_actions.duplicate(true)
		pending_actions.clear()
		var events := world.simulation.step([frame, remote], tick)
		game_events.emit(events)
		if not events.is_empty(): _send(22, {"round": store.state.round, "events": events}, 3)
		if tick % 3 == 0:
			_send(11, {"round": store.state.round, "tick": tick, "players": [Replication.player_data(world.simulation.players[0]), Replication.player_data(world.simulation.players[1])]}, 2, false)
			var data := Replication.world_data(world.simulation, tick)
			var signature := str([world.simulation.players[0].inventory.revision, world.simulation.players[1].inventory.revision, world.simulation.grenade.grenades.size(), world.simulation.grenade.flames.size()])
			if signature != last_world_signature or (tick % 30 == 0 and (not world.simulation.grenade.grenades.is_empty() or not world.simulation.grenade.flames.is_empty())):
				last_world_signature = signature
				_send(24, {"round": store.state.round, "world": data}, 3)
		var winner := MatchReducer.decide_round(world.simulation.players, tick >= director.deadline_tick)
		if winner != -2:
			_send_baseline()
			phase = CanonicalCodec.Phase.RESOLVING
			director.phase = phase
			_commit(MatchEvent.make(4, {"round": store.state.round, "winner": winner, "reason": "combat", "tick": tick}), "prepare")
			phase_changed.emit()
	else:
		world.simulation.tick = tick
		if not pending_snapshot.is_empty():
			last_snapshot_tick = pending_snapshot.tick
			tick = last_snapshot_tick + int(round(rtt_ms * 0.03))
			Replication.apply_player(world.simulation.players[0], pending_snapshot.players[0])
			var other: PlayerState = world.simulation.players[0]
			world.remote_interpolation.push(last_snapshot_tick, other.position, other.velocity, other.yaw, Time.get_ticks_msec())
			prediction.reconcile(world.simulation.players[1], pending_snapshot.players[1], world.simulation.movement)
			pending_snapshot = {}
		if phase != CanonicalCodec.Phase.FIGHTING or not baseline_ready: return
		frame.sample_tick = tick
		var input_data := Replication.input_data(frame, store.state.round)
		if not frame.actions.is_empty(): _send(20, input_data, 3, true)
		input_data.actions = []
		_send(10, input_data, 1, false)
		prediction.predict(world.simulation.players[1], frame, world.simulation.movement)

func _lost() -> void:
	if OS.is_debug_build(): print(JSON.stringify({"link_lost": true, "silent_ms": Time.get_ticks_msec() - last_receive_ms}))
	if not connected and resuming: return
	connected = false
	phase = CanonicalCodec.Phase.SUSPENDED
	resuming = true
	if not recovery.suspended:
		var r := recovery.on_link_lost(1, int(session_data.epoch), profile.boot_id, session_data.guest_boot if host else session_data.host_boot)
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

func _resume_data() -> Dictionary:
	return {"seq": store.state.last_seq, "hash": store.state.last_hash, "boot": profile.boot_id,
		"old_host_boot": session_data.host_boot, "old_guest_boot": session_data.guest_boot, "old_epoch": int(recovery.observation.get("old_epoch", session_data.epoch)),
		"remaining": recovery.remaining_ms() if local_continuous else 60000, "continuous": local_continuous, "terminal": recovery.expired or recovery.conflict}

func _offender() -> int:
	if remote_resume.is_empty(): return -1
	var host_boot: PackedByteArray = profile.boot_id if host else remote_resume.get("boot", PackedByteArray())
	var guest_boot: PackedByteArray = remote_resume.get("boot", PackedByteArray()) if host else profile.boot_id
	var continuous := local_slot if local_continuous else (1 - local_slot if remote_resume.get("continuous", false) else -1)
	return RecoveryCoordinator.identify_offender(host_boot != session_data.host_boot, guest_boot != session_data.guest_boot, continuous)

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
	if offender < 0:
		_stop_conflict("D08_UNAPPROVED")
		return
	var old_epoch: int = int(recovery.observation.get("old_epoch", remote_resume.get("old_epoch", 0)))
	_send(35, {"base_hash": store.state.last_hash, "offender": offender, "recovery_id": DuelIds.recovery_id(store.state.match_id, old_epoch).hex_encode()}, 3)

func _commit_recovery(d: Dictionary) -> void:
	var old_epoch: int = int(recovery.observation.get("old_epoch", remote_resume.get("old_epoch", 0)))
	var event := MatchEvent.make(5, {"round": store.state.round, "old_epoch": old_epoch, "new_epoch": epoch, "recovery_id": d.recovery_id,
		"offender": _offender(), "disposition": 0 if store.state.round_status == "OPEN" else 1})
	store.files._fault("before_recovery_commit")
	_commit(event, "recovered")
	store.files._fault("after_recovery_commit")

func _finish_resume() -> void:
	var info: Dictionary = peers[active_peer]
	session_data.host_boot = profile.boot_id if host else info.host_boot
	session_data.guest_boot = info.guest_boot if host else profile.boot_id
	session_data.epoch = epoch
	if not _save_session().ok:
		_stop_conflict("STORE_WRITE_FAILED")
		return
	resuming = false
	local_continuous = true
	recovery = RecoveryCoordinator.new()
	recovery.clock = clock
	recovery.store = store
	remote_resume = {}
	_set_status("復帰が完了しました。")

func _stop_conflict(reason: String) -> void:
	recovery.conflict = true
	if reason == "RECOVERY_EXPIRED":
		recovery.expired = true
		var saved := store.tombstone(reason, int(session_data.get("epoch", 0)))
		if not saved.ok: reason = "STORE_WRITE_FAILED"
	phase = CanonicalCodec.Phase.STORAGE_ERROR if reason.begins_with("STORE") else CanonicalCodec.Phase.CONFLICT
	_set_status("試合を停止しました: " + reason + "。得点を推測せず、保存記録を保持しています。")
	phase_changed.emit()

func rematch() -> void:
	rematch_ready[local_slot] = true
	_send(40, {"ready": true})
	if host and rematch_ready == [true, true]: _new_rematch()

func _new_rematch() -> void:
	var address: String = invitation_data.host
	var port: int = invitation_data.port
	var data := {"v": 1, "match": DuelIds.random_bytes(16).hex_encode(), "host": address, "port": port,
		"secret": DuelIds.random_bytes(32).hex_encode(), "rules": config.rules_hash.hex_encode(), "map": config.map_hash.hex_encode()}
	_send(42, {"code": DuelAuth.invitation(data)}, 3)
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
	director = RoundDirector.new()
	director.config = config
	phase = CanonicalCodec.Phase.LOBBY
	_set_status("再戦の接続を待っています…")

func close() -> void:
	if connected: _send(41, {"reason": 0, "old_epoch": epoch})
	transport.close()
	started = false
	connected = false

func _set_status(message: String) -> void:
	if status == message: return
	status = message
	status_changed.emit(message)
