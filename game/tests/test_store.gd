extends RefCounted

func test_ab_fallback(a: DuelAssertions) -> void:
	var files := AtomicFiles.new()
	var path := "user://tests/" + DuelIds.random_bytes(8).hex_encode() + "/settings"
	a.truth(files.save_ab(path, {"score": 1}).ok, "first generation")
	a.truth(files.save_ab(path, {"score": 2}).ok, "second generation")
	var f := FileAccess.open(path + ".b", FileAccess.WRITE)
	f.store_string("interrupted")
	f.close()
	var r := files.load_ab(path)
	a.truth(r.ok, "old generation survives")
	a.equal(r.value.value.score, 1, "old complete value")

func test_append_replay(a: DuelAssertions) -> void:
	var profile := DuelProfile.new()
	a.truth(profile.open("store_" + DuelIds.random_bytes(6).hex_encode()).ok, "profile")
	var mid := DuelIds.random_bytes(16)
	var store := RecoveryStore.new()
	store.initialize(profile, mid)
	var created := MatchEvent.make(1, {"match_id": mid, "rule_hash": DuelIds.random_bytes(32), "map_hash": DuelIds.random_bytes(32), "players": [{"slot": 0, "id": DuelIds.random_bytes(16)}, {"slot": 1, "id": DuelIds.random_bytes(16)}], "epoch": 1})
	a.truth(store.append_transaction([created, MatchEvent.make(2, {"round": 1, "first_slot": 0}), MatchEvent.make(3, {"round": 1}), MatchEvent.make(4, {"round": 1, "winner": 0, "reason": 0, "closed_tick": 100})]).ok, "durable chain")
	var hash_value := store.state.last_hash.duplicate()
	a.truth(store.load_match(mid).ok, "replay files")
	a.equal(store.state.scores, [1, 0], "replayed score")
	a.equal(store.state.last_hash, hash_value, "replayed hash")
	a.truth(store.append_raw(store.records[3]).ok, "idempotent record")
	var broken := store.records[3].duplicate()
	broken[20] ^= 1
	a.truth(not store.append_raw(broken).ok, "corrupt record rejected")
