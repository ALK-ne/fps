class_name DuelCheckpoint
extends RefCounted

const STATUSES := ["UNOPENED", "PREPARED", "OPEN", "CLOSED"]
const REASONS := ["", "TEN_WINS", "DISCONNECT_TIMEOUT", "RESPONSIBILITY_UNKNOWN"]
const KEYS := ["match_id", "rules_hash", "map_hash", "players", "round", "prepared_round", "first_slot", "scores", "round_status", "previous_winner", "match_winner", "terminal_reason", "last_seq", "last_hash", "epoch_highwater", "last_recovery_epoch", "recovery_receipts"]

static func encode(state: MatchState) -> PackedByteArray:
	var d := state.to_data()
	d.rules_hash = d.rule_hash
	d.erase("rule_hash")
	d.epoch_highwater = d.epoch_high_water
	d.erase("epoch_high_water")
	d.erase("phase")
	d.players = [state.players[0].id, state.players[1].id]
	d.round_status = STATUSES.find(state.round_status)
	d.terminal_reason = REASONS.find(state.terminal_reason)
	var bytes := CanonicalCodec.encode({"schema": 2, "state": d})
	bytes.append_array(DuelIds.digest(bytes))
	return bytes

static func decode(bytes: PackedByteArray, match_id: PackedByteArray) -> DuelResult:
	if bytes.size() < 33 or bytes.size() > 16384: return DuelResult.failure("STORE_CORRUPT")
	var body := bytes.slice(0, bytes.size() - 32)
	if DuelIds.digest(body) != bytes.slice(bytes.size() - 32): return DuelResult.failure("STORE_CORRUPT")
	var decoded := CanonicalCodec.decode(body, 16384)
	if not decoded.ok or not decoded.value is Dictionary or not StoreSchema.exact(decoded.value, ["schema", "state"]) or not decoded.value.get("state") is Dictionary: return DuelResult.failure("STORE_CORRUPT")
	if decoded.value.schema == 1: return DuelResult.failure("LEGACY_SCHEMA")
	if decoded.value.schema != 2: return DuelResult.failure("VERSION_MISMATCH")
	var d: Dictionary = decoded.value.state
	if not StoreSchema.exact(d, KEYS) or d.match_id != match_id: return DuelResult.failure("STORE_CORRUPT")
	for key in ["rules_hash", "map_hash", "last_hash"]:
		if not StoreSchema.bytes(d[key], 32): return DuelResult.failure("STORE_CORRUPT")
	for key in ["round", "prepared_round", "last_seq", "epoch_highwater", "last_recovery_epoch"]:
		if not StoreSchema.integer(d[key]): return DuelResult.failure("STORE_CORRUPT")
	if d.round < 1 or d.prepared_round != 0 or d.last_seq < 1 or d.epoch_highwater < 1 or d.last_recovery_epoch > d.epoch_highwater: return DuelResult.failure("STORE_CORRUPT")
	if not StoreSchema.integer(d.round_status, 3, 3) or not StoreSchema.integer(d.terminal_reason, 0, 3) or not StoreSchema.integer(d.first_slot, 0, 1): return DuelResult.failure("STORE_CORRUPT")
	for key in ["previous_winner", "match_winner"]:
		if not StoreSchema.integer(d[key], -1, 1): return DuelResult.failure("STORE_CORRUPT")
	if not d.players is Array or d.players.size() != 2 or not StoreSchema.bytes(d.players[0], 16) or not StoreSchema.bytes(d.players[1], 16) or d.players[0] == d.players[1]: return DuelResult.failure("STORE_CORRUPT")
	if not d.scores is Array or d.scores.size() != 2: return DuelResult.failure("STORE_CORRUPT")
	for score in d.scores:
		if not StoreSchema.integer(score, 0, 10): return DuelResult.failure("STORE_CORRUPT")
	if d.scores[0] + d.scores[1] > d.round or d.scores == [10, 10]: return DuelResult.failure("STORE_CORRUPT")
	if (d.terminal_reason == 0 and (d.match_winner != -1 or 10 in d.scores)) or (d.terminal_reason == 1 and (d.match_winner < 0 or d.scores[d.match_winner] != 10)) or (d.terminal_reason == 2 and d.match_winner < 0) or (d.terminal_reason == 3 and d.match_winner != -1): return DuelResult.failure("STORE_CORRUPT")
	if not d.recovery_receipts is Dictionary or d.recovery_receipts.size() > 1: return DuelResult.failure("STORE_CORRUPT")
	for id in d.recovery_receipts:
		if not id is String or id.length() != 32 or id.hex_decode().size() != 16 or not d.recovery_receipts[id] is bool or not d.recovery_receipts[id]: return DuelResult.failure("STORE_CORRUPT")
	d.rule_hash = d.rules_hash
	d.epoch_high_water = d.epoch_highwater
	d.players = [{"id": d.players[0], "slot": 0}, {"id": d.players[1], "slot": 1}]
	d.round_status = STATUSES[d.round_status]
	d.terminal_reason = REASONS[d.terminal_reason]
	d.phase = CanonicalCodec.Phase.SUSPENDED
	return DuelResult.success(MatchState.from_data(d))
