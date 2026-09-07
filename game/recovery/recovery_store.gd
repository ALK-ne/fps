class_name RecoveryStore
extends RefCounted

var root: String
var state := MatchState.new()
var records: Array[PackedByteArray] = []
var files := AtomicFiles.new()
var reducer := MatchReducer.new()
var checkpoint_seq: int = 0

func initialize(profile: DuelProfile, match_id: PackedByteArray) -> void:
	root = profile.root + "/matches/" + match_id.hex_encode()

func record_bytes(event: MatchEvent, seq: int, previous: PackedByteArray, match_id: PackedByteArray, rules: PackedByteArray) -> PackedByteArray:
	var payload := CanonicalCodec.encode(event.payload)
	var s := StreamPeerBuffer.new()
	s.put_u16(1)
	s.put_data(match_id)
	s.put_data(rules)
	s.put_u64(seq)
	s.put_data(previous if previous.size() == 32 else _zero_hash())
	s.put_u8(event.type)
	s.put_u32(payload.size())
	s.put_data(payload)
	var bytes := s.data_array
	bytes.append_array(DuelIds.digest(bytes))
	return bytes

func decode_record(bytes: PackedByteArray) -> DuelResult:
	if bytes.size() < 128 or bytes.size() > 8192: return DuelResult.failure("STORE_CORRUPT")
	var body := bytes.slice(0, bytes.size() - 32)
	if DuelIds.digest(body) != bytes.slice(bytes.size() - 32): return DuelResult.failure("STORE_CORRUPT")
	var s := StreamPeerBuffer.new()
	s.data_array = body
	if s.get_u16() != 1: return DuelResult.failure("VERSION_MISMATCH")
	var mid: PackedByteArray = s.get_data(16)[1]
	var rules: PackedByteArray = s.get_data(32)[1]
	var seq := s.get_u64()
	var previous: PackedByteArray = s.get_data(32)[1]
	var kind := s.get_u8()
	var count := s.get_u32()
	if count != s.get_available_bytes() or seq < 1: return DuelResult.failure("STORE_CORRUPT")
	var decoded := CanonicalCodec.decode(s.get_data(count)[1], 8192)
	if not decoded.ok or not decoded.value is Dictionary: return DuelResult.failure("STORE_CORRUPT")
	return DuelResult.success({"match_id": mid, "rules": rules, "seq": seq, "previous": previous, "event": MatchEvent.make(kind, decoded.value), "hash": bytes.slice(bytes.size() - 32)})

func load_match(match_id: PackedByteArray) -> DuelResult:
	state = MatchState.new()
	records.clear()
	checkpoint_seq = 0
	var checkpoints := DirAccess.open(root + "/checkpoints")
	if checkpoints != null:
		var checkpoint_names := checkpoints.get_files()
		checkpoint_names.sort()
		checkpoint_names.reverse()
		for filename in checkpoint_names:
			if not filename.ends_with(".bin"): continue
			var candidate := DuelCheckpoint.decode(FileAccess.get_file_as_bytes(root + "/checkpoints/" + filename), match_id)
			if candidate.ok:
				state = candidate.value
				checkpoint_seq = state.last_seq
				break
	var directory := DirAccess.open(root + "/records")
	if directory == null: return DuelResult.success(state)
	var names := directory.get_files()
	names.sort()
	for filename in names:
		if not filename.ends_with(".bin"): continue
		if int(filename.trim_suffix(".bin")) <= checkpoint_seq: continue
		var bytes := FileAccess.get_file_as_bytes(root + "/records/" + filename)
		var r := _validate_next(bytes)
		if not r.ok: return r
		if r.value.match_id != match_id: return DuelResult.failure("HISTORY_FORK")
		state = r.value
		records.append(bytes)
	return DuelResult.success(state)

func _validate_next(bytes: PackedByteArray) -> DuelResult:
	var r := decode_record(bytes)
	if not r.ok: return r
	var d: Dictionary = r.value
	var previous := state.last_hash if state.last_hash.size() == 32 else _zero_hash()
	if d.seq != state.last_seq + 1 or d.previous != previous: return DuelResult.failure("HISTORY_FORK")
	if state.last_seq > 0 and (d.match_id != state.match_id or d.rules != state.rule_hash): return DuelResult.failure("HISTORY_FORK")
	var next := reducer.apply(state, d.event)
	if not next.ok: return next
	if next.value.match_id != d.match_id or next.value.rule_hash != d.rules: return DuelResult.failure("HISTORY_FORK")
	next.value.last_seq = d.seq
	next.value.last_hash = d.hash
	return next

func append_raw(bytes: PackedByteArray) -> DuelResult:
	var decoded := decode_record(bytes)
	if not decoded.ok: return decoded
	var seq: int = decoded.value.seq
	if seq <= state.last_seq:
		var path := root + "/records/%016d.bin" % seq
		return DuelResult.success(state) if FileAccess.get_file_as_bytes(path) == bytes else DuelResult.failure("HISTORY_FORK")
	var next := _validate_next(bytes)
	if not next.ok: return next
	var result := files.write_new(root + "/records/%016d.bin" % seq, bytes)
	if not result.ok: return result
	state = next.value
	records.append(bytes)
	return DuelResult.success(state)

func append_transaction(events: Array) -> DuelResult:
	for event: MatchEvent in events:
		var mid: PackedByteArray = event.payload.match_id if state.match_id.is_empty() else state.match_id
		var rules: PackedByteArray = event.payload.rule_hash if state.rule_hash.is_empty() else state.rule_hash
		var bytes := record_bytes(event, state.last_seq + 1, state.last_hash, mid, rules)
		var r := append_raw(bytes)
		if not r.ok: return r
	return DuelResult.success(state)

func persist_observation(observation: Dictionary) -> DuelResult:
	return files.save_ab(root + "/observations/%d.json" % observation.old_epoch, observation)

func save_receipt(epoch: int, hash_value: PackedByteArray) -> DuelResult:
	return files.write_new(root + "/receipts/%d-%s.bin" % [epoch, hash_value.hex_encode()], hash_value)

func tombstone(reason: String, epoch: int) -> DuelResult:
	return files.save_ab(root + "/terminal.json", {"match_id": state.match_id, "seq": state.last_seq, "hash": state.last_hash, "old_epoch": epoch, "reason": reason})

func _zero_hash() -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(32)
	return bytes

func history_after(seq: int) -> DuelResult:
	var history: Array[PackedByteArray] = []
	for number in range(seq + 1, state.last_seq + 1):
		var path := root + "/records/%016d.bin" % number
		if not FileAccess.file_exists(path): return DuelResult.failure("CHECKPOINT_TOO_OLD")
		history.append(FileAccess.get_file_as_bytes(path))
	return DuelResult.success(history)

func hash_at(seq: int) -> PackedByteArray:
	if seq == 0: return PackedByteArray()
	if seq == state.last_seq: return state.last_hash
	var path := root + "/records/%016d.bin" % seq
	if FileAccess.file_exists(path):
		var record := decode_record(FileAccess.get_file_as_bytes(path))
		if record.ok: return record.value.hash
	var cp := root + "/checkpoints/%016d.bin" % seq
	if FileAccess.file_exists(cp):
		var decoded := DuelCheckpoint.decode(FileAccess.get_file_as_bytes(cp), state.match_id)
		if decoded.ok: return decoded.value.last_hash
	return PackedByteArray()

func save_checkpoint(bytes: PackedByteArray) -> DuelResult:
	var decoded := DuelCheckpoint.decode(bytes, state.match_id)
	if not decoded.ok: return decoded
	if decoded.value.last_seq != state.last_seq or bytes != DuelCheckpoint.encode(state): return DuelResult.failure("HISTORY_FORK")
	return files.write_new(root + "/checkpoints/%016d.bin" % state.last_seq, bytes)

func confirm_checkpoint(seq: int, hash_value: PackedByteArray) -> DuelResult:
	if seq != state.last_seq or hash_value != state.last_hash: return DuelResult.failure("HISTORY_FORK")
	var path := root + "/checkpoints/%016d.bin" % seq
	if not FileAccess.file_exists(path): return DuelResult.failure("STORE_CORRUPT")
	var saved := files.write_new(root + "/checkpoints/%016d.ack" % seq, hash_value)
	if not saved.ok: return saved
	checkpoint_seq = seq
	records.clear()
	var directory := DirAccess.open(root + "/checkpoints")
	var confirmed: Array[int] = []
	for filename in directory.get_files():
		if filename.ends_with(".ack"): confirmed.append(int(filename.trim_suffix(".ack")))
	confirmed.sort()
	# Keep two fully confirmed checkpoints and all records since the older one.
	if confirmed.size() < 2: return DuelResult.success()
	var oldest_to_keep := confirmed[confirmed.size() - 2]
	var record_directory := DirAccess.open(root + "/records")
	for filename in record_directory.get_files():
		if filename.ends_with(".bin") and int(filename.trim_suffix(".bin")) <= oldest_to_keep:
			files._fault("during_compaction")
			if record_directory.remove(filename) != OK: return DuelResult.failure("STORE_WRITE_FAILED")
	for old_seq in confirmed:
		if old_seq >= oldest_to_keep: continue
		for suffix in [".bin", ".ack"]:
			if directory.remove("%016d%s" % [old_seq, suffix]) != OK: return DuelResult.failure("STORE_WRITE_FAILED")
	return DuelResult.success()
