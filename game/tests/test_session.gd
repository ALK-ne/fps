extends RefCounted

func test_late_recovery_ack_does_not_add_penalty(a: DuelAssertions) -> void:
	var session := DuelSession.new()
	session.store.root = "user://tests/late_ack_" + DuelIds.random_bytes(8).hex_encode()
	session.store.state.match_id = DuelIds.random_bytes(16)
	session.store.state.last_hash = DuelIds.random_bytes(32)
	session.store.state.last_seq = 4
	session.store.state.last_recovery_epoch = 3
	session.store.state.scores = [0, 1]
	session.session_data = {"epoch": 3}
	session._stop_conflict("RECOVERY_EXPIRED")
	a.equal(session.terminal_status.resultStatus, 0, "no new abort or forfeit after committed recovery")
	a.equal(session.terminal_status.timerStatus, 2, "deadline evidence retained")
	a.equal(session.store.state.scores, [0, 1], "confirmed penalty unchanged")
	a.equal(session.store.state.last_seq, 4, "no second record invented")
	a.truth(session.diagnostic_only, "late confirmation cannot reopen gameplay")
	session._after_ack("recovered")
	a.truth(session.diagnostic_only, "late disk ACK preserves interlock")

func test_local_expiry_is_durable(a: DuelAssertions) -> void:
	var session := DuelSession.new()
	var profile := DuelProfile.new()
	a.truth(profile.open("expiry_" + DuelIds.random_bytes(6).hex_encode()).ok, "profile")
	var mid := DuelIds.random_bytes(16)
	session.store.initialize(profile, mid)
	session.session_data = {"epoch": 3}
	session.resuming = true
	a.truth(session.store.append_transaction([MatchEvent.make(1, {"match_id": mid, "rule_hash": DuelIds.random_bytes(32), "map_hash": DuelIds.random_bytes(32), "players": [{"slot": 0, "id": DuelIds.random_bytes(16)}, {"slot": 1, "id": DuelIds.random_bytes(16)}], "epoch": 1})]).ok, "initial durable record")
	session._stop_conflict("RECOVERY_EXPIRED")
	a.equal(session.phase, CanonicalCodec.Phase.CONFLICT, "local expiry stops gameplay")
	a.truth(session.recovery.expired, "expiry survives coordinator checks")
	var saved := session.store.files.load_ab(session.store.root + "/terminal.json")
	a.truth(saved.ok, "terminal stored with checksum")
	a.equal(saved.value.value.status.timerStatus, 2, "durable expiry evidence")
	a.equal(saved.value.value.status.resultStatus, 2, "approved abort without responsibility evidence")
	a.equal(saved.value.value.status.seq, 1, "references confirmed history")
	a.equal(session.store.state.scores, [0, 0], "no invented wins")
	var notice_id: PackedByteArray = session.terminal_status.noticeId
	session._stop_conflict("HISTORY_FORK")
	a.equal(session.terminal_status.resultStatus, 2, "subsequent conflict preserves the existing outcome")
	a.equal(session.terminal_status.noticeId, notice_id, "existing certificate is not replaced")
	a.equal(session.terminal_status.resumeBlock, 3, "history conflict is a separate interlock")

func test_terminal_write_failure_is_visible(a: DuelAssertions) -> void:
	var path := "user://tests/blocked_" + DuelIds.random_bytes(6).hex_encode()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("a file cannot contain child records")
	file.close()
	var session := DuelSession.new()
	session.store.root = path
	session._stop_conflict("RECOVERY_EXPIRED")
	a.equal(session.phase, CanonicalCodec.Phase.STORAGE_ERROR, "cannot report durable expiry after write failure")
	a.truth(session.status.contains("STORE_WRITE_FAILED"), "explicit storage failure")
	a.truth(session.recovery.expired and session.recovery.conflict, "write failure never reopens gameplay")


func test_terminal_cannot_be_reopened_by_old_phase(a: DuelAssertions) -> void:
	var session := DuelSession.new()
	session.connected = true
	session.host = true
	session.store.state.terminal_reason = "RESPONSIBILITY_UNKNOWN"
	session.store.state.phase = CanonicalCodec.Phase.MATCH_RESULT
	session.phase = CanonicalCodec.Phase.MATCH_RESULT
	session.director.phase = CanonicalCodec.Phase.COUNTDOWN
	session.director.deadline_tick = 1
	session.tick = 100
	session.physics(InputFrame.new())
	a.equal(session.phase, CanonicalCodec.Phase.MATCH_RESULT, "old countdown cannot restart terminal match")
	session.host = false
	session._dispatch(23, {"round": 0, "phase": 5, "revision": 999})
	a.equal(session.phase, CanonicalCodec.Phase.MATCH_RESULT, "late phase message cannot reopen terminal match")
