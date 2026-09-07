extends RefCounted

func test_compaction_and_fallback(a: DuelAssertions) -> void:
	var profile := DuelProfile.new()
	a.truth(profile.open("checkpoint_" + DuelIds.random_bytes(6).hex_encode()).ok, "profile")
	var mid := DuelIds.random_bytes(16)
	var store := RecoveryStore.new()
	store.initialize(profile, mid)
	a.truth(store.append_transaction([MatchEvent.make(1, {"match_id": mid, "rule_hash": DuelIds.random_bytes(32), "players": [{"slot": 0}, {"slot": 1}], "epoch": 1})]).ok, "created")
	for round_number in range(1, 2001):
		var result := store.append_transaction([MatchEvent.make(2, {"round": round_number}), MatchEvent.make(3, {"round": round_number}), MatchEvent.make(4, {"round": round_number, "winner": -1})])
		if not result.ok:
			a.truth(false, "draw round %d" % round_number)
			return
		if round_number % 128 == 0:
			a.truth(store.save_checkpoint(DuelCheckpoint.encode(store.state)).ok, "checkpoint durable")
			a.truth(store.confirm_checkpoint(store.state.last_seq, store.state.last_hash).ok, "checkpoint confirmed")
	var expected := store.state.last_hash.duplicate()
	a.equal(store.state.scores, [0, 0], "2000 draws preserve score")
	a.truth(store.records.size() < 384, "bounded memory history")
	var record_names := DirAccess.open(store.root + "/records").get_files()
	a.truth(record_names.size() < 768, "bounded disk history")
	a.truth(store.load_match(mid).ok, "checkpoint plus suffix reload")
	a.equal(store.state.last_hash, expected, "exact final history hash")
	var cp_path := store.root + "/checkpoints/%016d.bin" % store.checkpoint_seq
	var damaged := FileAccess.open(cp_path, FileAccess.WRITE)
	damaged.store_string("interrupted checkpoint")
	damaged.close()
	a.truth(store.load_match(mid).ok, "older checkpoint survives corruption")
	a.equal(store.state.last_hash, expected, "older checkpoint plus retained records")
	a.equal(store.state.round, 2000, "all rounds recovered")
	a.truth(not store.history_after(1).ok, "pruned history explicitly rejected")
