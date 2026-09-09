class_name RecoveryStore
extends RefCounted

var root: String
var state := MatchState.new()
var records: Array[PackedByteArray] = []
var files := AtomicFiles.new()
var reducer := MatchReducer.new()
var checkpoint_seq: int = 0
var legacy: bool = false
var floor_seq: int = 0

func initialize(profile: DuelProfile, match_id: PackedByteArray) -> void:
	root = profile.root + "/matches/" + match_id.hex_encode()

func record_bytes(event: MatchEvent, seq: int, previous: PackedByteArray, match_id: PackedByteArray, rules: PackedByteArray) -> PackedByteArray:
	var prev := previous if previous.size() == 32 else _zero_hash()
	var value := StoreSchema.payload(event, seq, prev)
	if not StoreSchema.validate(event.type, value): return PackedByteArray()
	var payload := CanonicalCodec.encode(value)
	var s := StreamPeerBuffer.new()
	s.put_u16(2)
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
	var schema := s.get_u16()
	if schema not in [1, 2]: return DuelResult.failure("VERSION_MISMATCH")
	var mid: PackedByteArray = s.get_data(16)[1]
	var rules: PackedByteArray = s.get_data(32)[1]
	var seq := s.get_u64()
	var previous: PackedByteArray = s.get_data(32)[1]
	var kind := s.get_u8()
	var count := s.get_u32()
	if count != s.get_available_bytes() or seq < 1: return DuelResult.failure("STORE_CORRUPT")
	var decoded := CanonicalCodec.decode(s.get_data(count)[1], 8192)
	if not decoded.ok or not decoded.value is Dictionary: return DuelResult.failure("STORE_CORRUPT")
	if schema == 2:
		if not StoreSchema.validate(kind, decoded.value): return DuelResult.failure("STORE_CORRUPT")
		if kind == 5 and (decoded.value.base_seq != seq - 1 or decoded.value.base_hash != previous): return DuelResult.failure("HISTORY_FORK")
	return DuelResult.success({"schema": schema, "match_id": mid, "rules": rules, "seq": seq, "previous": previous, "event": StoreSchema.event(kind, decoded.value, mid, rules) if schema == 2 else MatchEvent.make(kind, decoded.value), "hash": bytes.slice(bytes.size() - 32)})

func load_match(match_id: PackedByteArray) -> DuelResult:
	state = MatchState.new()
	records.clear()
	checkpoint_seq = 0
	floor_seq = 0
	legacy = false
	var checkpoints := DirAccess.open(root + "/checkpoints")
	if checkpoints != null:
		var checkpoint_names := checkpoints.get_files()
		checkpoint_names.sort()
		checkpoint_names.reverse()
		for filename in checkpoint_names:
			if filename.ends_with(".ack"):
				var number := int(filename.trim_suffix(".ack"))
				if _valid_ack(number, match_id) and (floor_seq == 0 or number < floor_seq): floor_seq = number
		for filename in checkpoint_names:
			if not filename.ends_with(".bin"): continue
			var candidate := DuelCheckpoint.decode(AtomicFiles.read_bounded(root + "/checkpoints/" + filename, 16384), match_id)
			if candidate.error_code == "LEGACY_SCHEMA": legacy = true
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
		var bytes := AtomicFiles.read_bounded(root + "/records/" + filename, 8192)
		var version := decode_record(bytes)
		if not version.ok: return version
		if state.last_seq > 0 and (version.value.schema == 1) != legacy: return DuelResult.failure("LEGACY_SCHEMA")
		var r := _validate_next(bytes)
		if not r.ok: return r
		if r.value.match_id != match_id: return DuelResult.failure("HISTORY_FORK")
		state = r.value
		legacy = legacy or decode_record(bytes).value.schema == 1
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
	if legacy: return DuelResult.failure("LEGACY_SCHEMA")
	var decoded := decode_record(bytes)
	if not decoded.ok: return decoded
	if decoded.value.schema != 2: return DuelResult.failure("LEGACY_SCHEMA")
	var seq: int = decoded.value.seq
	if seq < floor_seq: return DuelResult.failure("STALE_HISTORY")
	if seq == floor_seq and seq > 0:
		return DuelResult.success(state) if decoded.value.hash == hash_at(seq) else DuelResult.failure("HISTORY_FORK")
	if seq <= state.last_seq:
		var path := root + "/records/%016d.bin" % seq
		return DuelResult.success(state) if AtomicFiles.read_bounded(path, 8192) == bytes else DuelResult.failure("HISTORY_FORK")
	var next := _validate_next(bytes)
	if not next.ok: return next
	files.current_record_type = decoded.value.event.type
	var result := files.write_new(root + "/records/%016d.bin" % seq, bytes)
	files.current_record_type = 0
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

func prune_observations() -> DuelResult:
	# Only a durable recovery receipt authorizes deleting resolved observations.
	if state.last_recovery_epoch < 1: return DuelResult.success()
	var directory := DirAccess.open(root + "/observations")
	if directory == null: return DuelResult.success()
	var resolved: Array[int] = []
	var names: Dictionary = {}
	for filename in directory.get_files():
		if not filename.ends_with(".json.a") and not filename.ends_with(".json.b"): continue
		var stem := filename.trim_suffix(".a").trim_suffix(".b").trim_suffix(".json")
		if not stem.is_valid_int() or str(int(stem)) != stem or int(stem) < 1: continue
		var old_epoch := int(stem)
		if old_epoch > state.last_recovery_epoch: continue
		if not names.has(old_epoch):
			names[old_epoch] = []
			resolved.append(old_epoch)
		names[old_epoch].append(filename)
	resolved.sort()
	for index in maxi(0, resolved.size() - 2):
		for filename in names[resolved[index]]:
			if directory.is_link(filename): return DuelResult.failure("STORE_CORRUPT")
			if directory.remove(filename) != OK: return DuelResult.failure("STORE_WRITE_FAILED")
	return DuelResult.success()

func _zero_hash() -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(32)
	return bytes

func history_after(seq: int) -> DuelResult:
	var history: Array[PackedByteArray] = []
	for number in range(seq + 1, state.last_seq + 1):
		var path := root + "/records/%016d.bin" % number
		if not FileAccess.file_exists(path): return DuelResult.failure("CHECKPOINT_TOO_OLD")
		history.append(AtomicFiles.read_bounded(path, 8192))
	return DuelResult.success(history)

func hash_at(seq: int) -> PackedByteArray:
	if seq == 0: return PackedByteArray()
	if seq == state.last_seq: return state.last_hash
	var path := root + "/records/%016d.bin" % seq
	if FileAccess.file_exists(path):
		var record := decode_record(AtomicFiles.read_bounded(path, 8192))
		if record.ok: return record.value.hash
	var cp := root + "/checkpoints/%016d.bin" % seq
	if FileAccess.file_exists(cp):
		var decoded := DuelCheckpoint.decode(AtomicFiles.read_bounded(cp, 16384), state.match_id)
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
	var checkpoint_bytes := AtomicFiles.read_bounded(path, 16384)
	var ack := CanonicalCodec.encode({"schema": 2, "seq": seq, "hash": hash_value, "checkpoint_hash": DuelIds.digest(checkpoint_bytes)})
	ack.append_array(DuelIds.digest(ack))
	var saved := files.write_new(root + "/checkpoints/%016d.ack" % seq, ack)
	if not saved.ok: return saved
	checkpoint_seq = seq
	records.clear()
	var directory := DirAccess.open(root + "/checkpoints")
	var confirmed: Array[int] = []
	for filename in directory.get_files():
		if filename.ends_with(".ack"):
			var number := int(filename.trim_suffix(".ack"))
			if _valid_ack(number): confirmed.append(number)
	confirmed.sort()
	# Keep two fully confirmed checkpoints and all records since the older one.
	if confirmed.size() < 2: return DuelResult.success()
	var oldest_to_keep := confirmed[confirmed.size() - 2]
	floor_seq = oldest_to_keep
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

func _valid_ack(seq: int, match_id: PackedByteArray = PackedByteArray()) -> bool:
	var prefix := root + "/checkpoints/%016d" % seq
	var bytes := AtomicFiles.read_bounded(prefix + ".ack", 1024)
	if bytes.size() < 33 or bytes.size() > 1024: return false
	var body := bytes.slice(0, bytes.size() - 32)
	if DuelIds.digest(body) != bytes.slice(bytes.size() - 32): return false
	var decoded := CanonicalCodec.decode(body, 1024)
	if not decoded.ok or not decoded.value is Dictionary or not StoreSchema.exact(decoded.value, ["schema", "seq", "hash", "checkpoint_hash"]): return false
	var d: Dictionary = decoded.value
	if d.schema != 2 or d.seq != seq or not StoreSchema.bytes(d.hash, 32) or not StoreSchema.bytes(d.checkpoint_hash, 32): return false
	var checkpoint := AtomicFiles.read_bounded(prefix + ".bin", 16384)
	var decoded_checkpoint := DuelCheckpoint.decode(checkpoint, state.match_id if match_id.is_empty() else match_id)
	return d.checkpoint_hash == DuelIds.digest(checkpoint) and decoded_checkpoint.ok and decoded_checkpoint.value.last_seq == seq and decoded_checkpoint.value.last_hash == d.hash
