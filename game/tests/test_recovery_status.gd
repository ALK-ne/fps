extends RefCounted

func test_forfeit_certificate_prefix_and_host_record(a: DuelAssertions) -> void:
	var host := RecoveryStore.new()
	host.root = "user://tests/forfeit_" + DuelIds.random_bytes(8).hex_encode()
	var mid := DuelIds.random_bytes(16)
	var created := MatchEvent.make(1, {"match_id": mid, "rule_hash": DuelIds.random_bytes(32), "map_hash": DuelIds.random_bytes(32), "players": [{"id": DuelIds.random_bytes(16), "slot": 0}, {"id": DuelIds.random_bytes(16), "slot": 1}], "epoch": 1})
	a.truth(host.append_transaction([created, MatchEvent.make(2, {"round": 1, "first_slot": 0}), MatchEvent.make(3, {"round": 1})]).ok, "common history durable")
	var guest := RecoveryStore.new()
	guest.root = host.root + "_guest"
	for record in host.records: a.truth(guest.append_raw(record).ok, "guest has common prefix")
	var notice := RecoveryStatus.create(host.state, 1, DuelIds.random_bytes(16), {}, "RECOVERY_EXPIRED", 0)
	a.truth(guest.persist_terminal_notice(notice, false, 2).ok, "guest saves certificate only")
	a.equal(guest.state.last_seq, 3, "guest cannot author host record")
	# Simulate interruption after certificate persistence, before host record append.
	a.truth(host.files.save_ab(host.root + "/terminal.json", {"policy": GameConfig.RECOVERY_POLICY, "status": notice}).ok, "proof durable before record")
	a.truth(host.load_match(mid).ok, "restart from common prefix")
	a.truth(host.persist_terminal_notice(notice, true, 2).ok, "host finishes forfeit after interruption")
	a.equal(host.state.last_seq, 4, "one host-owned terminal record")
	a.equal(host.state.terminal_reason, "DISCONNECT_TIMEOUT", "durable forfeit classification")
	a.equal(host.state.match_winner, 1, "winner follows proven offender")
	a.equal(host.state.scores, [0, 0], "forfeit changes match winner without new round point")
	a.truth(host.validate_terminal_notice(notice) and guest.validate_terminal_notice(notice), "both accept the same prefix certificate")
	a.truth(host.persist_terminal_notice(notice, true, 3).ok, "replayed notice idempotent")
	a.equal(host.state.last_seq, 4, "no duplicate terminal record")
	a.truth(host.load_match(mid).ok and host.validate_terminal_notice(notice), "record and certificate validate after reload")
	var forged := notice.duplicate(true)
	forged.winner = 0
	forged.offender = 1
	a.truth(not host.validate_terminal_notice(forged), "certificate cannot replace committed winner")
	forged = notice.duplicate(true)
	forged.hash = DuelIds.random_bytes(32)
	a.truth(not host.validate_terminal_notice(forged), "certificate cannot reference a different prefix")

func test_closed_index_idempotence_and_manifest_fallback(a: DuelAssertions) -> void:
	var index := ClosedIndex.new()
	index.root = "user://tests/closed_" + DuelIds.random_bytes(8).hex_encode()
	var first := DuelIds.random_bytes(16)
	var second := DuelIds.random_bytes(16)
	a.truth(index.append(first, 1, 2).ok, "first closed ID durable")
	a.truth(index.append(first, 1, 2).ok, "duplicate close idempotent")
	a.equal(index._manifest().value.total, 1, "duplicate does not grow index")
	a.truth(index.append(second, 1, 3).ok, "second closed ID durable")
	a.equal(index.lookup(first).value.result, 2, "retains abort classification")
	a.equal(index.lookup(second).value.result, 3, "retains terminal classification")
	var file := FileAccess.open(index.root + "/manifest.b", FileAccess.WRITE)
	file.store_string("partial manifest")
	file.close()
	a.truth(index.lookup(first).ok, "previous manifest still references retained immutable tail")
	a.equal(index.lookup(second).error_code, "NOT_FOUND", "unconfirmed generation cannot invent a closed ID")

func test_status_cannot_invent_winner(a: DuelAssertions) -> void:
	var state := MatchState.new()
	state.match_id = DuelIds.random_bytes(16)
	state.last_seq = 3
	state.last_hash = DuelIds.random_bytes(32)
	state.round = 1
	var status := RecoveryStatus.create(state, 1, DuelIds.random_bytes(16), {}, "RECOVERY_EXPIRED", -1)
	a.truth(RecoveryStatus.validate(status, state), "approved abort certificate")
	a.equal(status.winner, -1, "no speculative winner")
	status.winner = 0
	a.truth(not RecoveryStatus.validate(status, state), "abort cannot claim a winner")
	status = RecoveryStatus.create(state, 1, DuelIds.random_bytes(16), {}, "CLOCK_UNCERTAIN", -1)
	a.equal([status.timerStatus, status.resumeBlock, status.resultStatus], [3, 6, 0], "clock uncertainty is separate from expiry and outcome")
	status = RecoveryStatus.create(state, 1, DuelIds.random_bytes(16), {}, "RECOVERY_EXPIRED", 1)
	a.truth(RecoveryStatus.validate(status, state), "forfeit with responsibility and deadline evidence")
	status.evidence = 1
	a.truth(not RecoveryStatus.validate(status, state), "continuous observation alone cannot prove forfeit")

func test_closed_detail_retention_keeps_rejection_index(a: DuelAssertions) -> void:
	var profile_root := "user://tests/retention_" + DuelIds.random_bytes(6).hex_encode()
	var index := ClosedIndex.new()
	index.root = profile_root + "/closed-index"
	var ids: Array[PackedByteArray] = []
	for number in 102:
		var mid := DuelIds.random_bytes(16)
		ids.append(mid)
		if not index.append(mid, 1, 2).ok:
			a.truth(false, "index append")
			return
	for mid in [ids[0], ids.back()]:
		a.truth(index.files.write_new(profile_root + "/matches/" + mid.hex_encode() + "/session.bin", PackedByteArray([1, 2, 3])).ok, "test detail created")
	a.truth(index.prune_details(profile_root).ok, "prunes only indexed older closed details")
	a.truth(not DirAccess.dir_exists_absolute(profile_root + "/matches/" + ids[0].hex_encode()), "old secret detail removed")
	a.truth(FileAccess.file_exists(profile_root + "/matches/" + ids.back().hex_encode() + "/session.bin"), "latest hundred detail retained")
	a.truth(index.lookup(ids[0]).ok, "old ID still rejected after detail removal")
	a.truth(not index._remove_owned(profile_root, ProjectSettings.globalize_path(profile_root + "/matches/")).ok, "cleanup cannot escape exact matches directory")
