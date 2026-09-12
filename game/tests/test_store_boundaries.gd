extends RefCounted

func test_checkpoint_record_threshold_without_round_growth(a: DuelAssertions) -> void:
	var store := RecoveryStore.new()
	store.state.round = 1
	store.state.round_status = "CLOSED"
	store.state.last_seq = 1023
	a.truth(not store.checkpoint_due(), "below retained record threshold")
	store.state.last_seq = 1024
	a.truth(store.checkpoint_due(), "same round keep receipts trigger compaction")
	store.checkpoint_seq = 1024
	a.truth(not store.checkpoint_due(), "confirmed checkpoint resets threshold")
	store.state.last_seq = 2048
	store.state.round_status = "OPEN"
	a.truth(not store.checkpoint_due(), "never checkpoint live combat")
	store.state.round_status = "CLOSED"
	a.truth(store.checkpoint_due(), "next thousand records trigger independently of round")

func test_bounded_reads_and_ab_fallback(a: DuelAssertions) -> void:
	var files := AtomicFiles.new()
	var path := "user://tests/bounds_" + DuelIds.random_bytes(8).hex_encode()
	a.truth(files.save_ab(path, {"value": 1}).ok, "first generation")
	a.truth(files.save_ab(path, {"value": 2}).ok, "second generation")
	var file := FileAccess.open(path + ".b", FileAccess.WRITE)
	file.seek(1048576)
	file.store_8(1)
	file.close()
	a.truth(AtomicFiles.read_bounded(path + ".b", 65568).is_empty(), "oversize rejected before buffer allocation")
	a.equal(files.load_ab(path).value.value.value, 1, "oversized newest generation falls back")
	a.truth(not files.write_new(path + ".b", PackedByteArray([1])).ok, "oversized immutable file cannot be overwritten")

func test_session_schema_round_trip_and_rejections(a: DuelAssertions) -> void:
	var host_id := DuelIds.random_bytes(16)
	var guest_id := DuelIds.random_bytes(16)
	var data := {"invitation": {"match": DuelIds.random_bytes(16).hex_encode(), "rules": DuelIds.random_bytes(32).hex_encode(), "map": DuelIds.random_bytes(32).hex_encode(), "secret": DuelIds.random_bytes(32).hex_encode(), "host": "127.0.0.1", "port": 27846}, "host_id": host_id, "guest_id": guest_id, "host_boot": DuelIds.random_bytes(16), "guest_boot": DuelIds.random_bytes(16), "epoch": 7}
	var saved := StoreSchema.session_value(data)
	for id in [host_id, guest_id]:
		var loaded := StoreSchema.session_data(saved, id)
		a.truth(loaded.ok, "either local role restores")
		a.equal(loaded.value.host, id == host_id, "role derives from durable player identity")
		a.equal(loaded.value.epoch, 7, "epoch retained")
	var broken := saved.duplicate(true)
	broken.endpoint.port = 27846.0
	a.truth(not StoreSchema.session_data(broken, host_id).ok, "float port rejected")
	broken = saved.duplicate(true)
	broken.extra = 1
	a.truth(not StoreSchema.session_data(broken, host_id).ok, "unknown keys rejected")
	broken = saved.duplicate(true)
	broken.players[1] = host_id
	a.truth(not StoreSchema.session_data(broken, host_id).ok, "duplicate players rejected")
	a.truth(not StoreSchema.session_data(saved, DuelIds.random_bytes(16)).ok, "foreign profile rejected")
	a.equal(StoreSchema.session_data(data, host_id).error_code, "LEGACY_SCHEMA", "old internal layout cannot resume")

func test_observation_cleanup_requires_receipt(a: DuelAssertions) -> void:
	var store := RecoveryStore.new()
	store.root = "user://tests/observations_" + DuelIds.random_bytes(8).hex_encode()
	for epoch in range(1, 6):
		a.truth(store.persist_observation({"old_epoch": epoch}).ok, "observation saved")
	a.truth(store.prune_observations().ok, "no receipt leaves all observations")
	a.truth(store.files.load_ab(store.root + "/observations/1.json").ok, "old record protected before receipt")
	store.state.last_recovery_epoch = 4
	a.truth(store.prune_observations().ok, "receipt permits retention cleanup")
	for epoch in [1, 2]:
		a.equal(store.files.load_ab(store.root + "/observations/%d.json" % epoch).error_code, "NOT_FOUND", "old resolved record removed")
	for epoch in [3, 4, 5]:
		a.truth(store.files.load_ab(store.root + "/observations/%d.json" % epoch).ok, "two resolved and unresolved retained")
