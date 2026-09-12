extends RefCounted

func _record(kind: int, payload: Dictionary, mid: PackedByteArray, rules: PackedByteArray, seq: int, previous: PackedByteArray) -> PackedByteArray:
	var stream := StreamPeerBuffer.new()
	stream.put_u16(1)
	stream.put_data(mid)
	stream.put_data(rules)
	stream.put_u64(seq)
	stream.put_data(previous)
	stream.put_u8(kind)
	var body := CanonicalCodec.encode(payload)
	stream.put_u32(body.size())
	stream.put_data(body)
	var bytes := stream.data_array
	bytes.append_array(DuelIds.digest(bytes))
	return bytes

func _checkpoint(state: MatchState) -> PackedByteArray:
	var data := state.to_data()
	data.erase("map_hash")
	data.erase("first_slot")
	var bytes := CanonicalCodec.encode({"schema": 1, "state": data})
	bytes.append_array(DuelIds.digest(bytes))
	return bytes

func test_legacy_validated_read_only_and_checkpoint(a: DuelAssertions) -> void:
	var store := RecoveryStore.new()
	store.root = "user://tests/legacy_" + DuelIds.random_bytes(8).hex_encode()
	var mid := DuelIds.random_bytes(16)
	var rules := DuelIds.random_bytes(32)
	var created := {"match_id": mid, "rule_hash": rules, "players": [{"id": DuelIds.random_bytes(16), "slot": 0}, {"id": DuelIds.random_bytes(16), "slot": 1}], "epoch": 1}
	var payloads := [created, {"round": 1, "first_slot": 1}, {"round": 1}, {"round": 1, "winner": 0, "reason": "combat", "tick": 100}]
	var previous := PackedByteArray()
	previous.resize(32)
	for index in payloads.size():
		var bytes := _record(index + 1, payloads[index], mid, rules, index + 1, previous)
		a.truth(store.files.write_new(store.root + "/records/%016d.bin" % (index + 1), bytes).ok, "old chain saved unchanged")
		previous = bytes.slice(bytes.size() - 32)
	a.truth(store.load_match(mid).ok, "old chain validated")
	a.equal(store.state.scores, [1, 0], "only validated old score exposed")
	a.truth(store.legacy, "read-only marker retained")
	a.equal(store.append_raw(store.records[0]).error_code, "LEGACY_SCHEMA", "old chain cannot be appended")
	var checkpoint := _checkpoint(store.state)
	a.truth(DuelCheckpoint.decode_legacy(checkpoint, mid).ok, "strict legacy checkpoint accepted for display")
	var cp_store := RecoveryStore.new()
	cp_store.root = store.root + "_checkpoint"
	a.truth(cp_store.files.write_new(cp_store.root + "/checkpoints/%016d.bin" % 4, checkpoint).ok, "old checkpoint saved")
	a.truth(cp_store.load_match(mid).ok and cp_store.legacy, "checkpoint-only old match stays read-only")
	a.equal(cp_store.state.scores, [1, 0], "compacted old history remains readable")
	var corrupt := RecoveryStore.new()
	corrupt.root = store.root + "_corrupt"
	a.truth(corrupt.files.write_new(corrupt.root + "/checkpoints/0000000000000004.bin", PackedByteArray([1, 2, 3])).ok, "corrupt checkpoint fixture")
	a.equal(corrupt.load_match(mid).error_code, "STORE_CORRUPT", "no valid checkpoint cannot invent an empty history")
	store.state.scores = [1.0, 0]
	a.truth(not DuelCheckpoint.decode_legacy(_checkpoint(store.state), mid).ok, "float score rejected")
	previous.fill(0)
	for invalid in [17, {}, "broken", [1, 2]]:
		var damaged := created.duplicate(true)
		damaged.players = invalid
		a.truth(not store.decode_record(_record(1, damaged, mid, rules, 1, previous)).ok, "malformed old players rejected")
	var damaged := created.duplicate(true)
	damaged.players[0].id = 12
	previous.fill(0)
	a.truth(not store.decode_record(_record(1, damaged, mid, rules, 1, previous)).ok, "nested type corruption rejected before reducer")
