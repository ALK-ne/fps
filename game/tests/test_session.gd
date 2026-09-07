extends RefCounted

func test_remote_expiry_is_durable(a: DuelAssertions) -> void:
	var session := DuelSession.new()
	var profile := DuelProfile.new()
	a.truth(profile.open("expiry_" + DuelIds.random_bytes(6).hex_encode()).ok, "profile")
	var mid := DuelIds.random_bytes(16)
	session.store.initialize(profile, mid)
	session.session_data = {"epoch": 3}
	session.resuming = true
	a.truth(session.store.append_transaction([MatchEvent.make(1, {"match_id": mid, "rule_hash": DuelIds.random_bytes(32), "players": [{"slot": 0}, {"slot": 1}], "epoch": 1})]).ok, "initial durable record")
	session._dispatch(32, {"terminal": true})
	a.equal(session.phase, CanonicalCodec.Phase.CONFLICT, "authenticated peer expiry stops gameplay")
	a.truth(session.recovery.expired, "expiry survives coordinator checks")
	var saved := session.store.files.load_ab(session.store.root + "/terminal.json")
	a.truth(saved.ok, "terminal stored with checksum")
	a.equal(saved.value.value.reason, "RECOVERY_EXPIRED", "durable refusal reason")
	a.equal(saved.value.value.seq, 1, "references confirmed history")
	a.equal(session.store.state.scores, [0, 0], "no invented wins")

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
