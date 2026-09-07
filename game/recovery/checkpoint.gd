class_name DuelCheckpoint
extends RefCounted

static func encode(state: MatchState) -> PackedByteArray:
	var bytes := CanonicalCodec.encode({"schema": 1, "state": state.to_data()})
	bytes.append_array(DuelIds.digest(bytes))
	return bytes

static func decode(bytes: PackedByteArray, match_id: PackedByteArray) -> DuelResult:
	if bytes.size() < 33 or bytes.size() > 16384: return DuelResult.failure("STORE_CORRUPT")
	var body := bytes.slice(0, bytes.size() - 32)
	if DuelIds.digest(body) != bytes.slice(bytes.size() - 32): return DuelResult.failure("STORE_CORRUPT")
	var decoded := CanonicalCodec.decode(body, 16384)
	if not decoded.ok or not decoded.value is Dictionary or decoded.value.get("schema") != 1 or not decoded.value.get("state") is Dictionary: return DuelResult.failure("STORE_CORRUPT")
	var d: Dictionary = decoded.value.state
	if d.get("match_id") != match_id or not d.get("last_seq") is int or d.last_seq < 1 or not d.get("last_hash") is PackedByteArray or d.last_hash.size() != 32: return DuelResult.failure("STORE_CORRUPT")
	if d.get("round_status") != "CLOSED" or not d.get("round") is int or d.round < 1: return DuelResult.failure("STORE_CORRUPT")
	if not d.get("scores") is Array or d.scores.size() != 2: return DuelResult.failure("STORE_CORRUPT")
	for score in d.scores:
		if not score is int or score < 0 or score > 10: return DuelResult.failure("STORE_CORRUPT")
	return DuelResult.success(MatchState.from_data(d))
