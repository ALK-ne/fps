class_name MatchState
extends RefCounted

var match_id: PackedByteArray = PackedByteArray()
var rule_hash: PackedByteArray = PackedByteArray()
var players: Array = []
var round: int = 0
var prepared_round: int = 0
var scores: Array = [0, 0]
var phase: int = CanonicalCodec.Phase.LOBBY
var round_status: String = "UNOPENED"
var previous_winner: int = -1
var match_winner: int = -1
var terminal_reason: String = ""
var last_seq: int = 0
var last_hash: PackedByteArray = PackedByteArray()
var epoch_high_water: int = 0
var last_recovery_epoch: int = 0
var recovery_receipts: Dictionary = {}

func to_data() -> Dictionary:
	return {"match_id": match_id, "rule_hash": rule_hash, "players": players, "round": round,
		"prepared_round": prepared_round, "scores": scores, "phase": phase, "round_status": round_status,
		"previous_winner": previous_winner, "match_winner": match_winner, "terminal_reason": terminal_reason,
		"last_seq": last_seq, "last_hash": last_hash, "epoch_high_water": epoch_high_water,
		"last_recovery_epoch": last_recovery_epoch, "recovery_receipts": recovery_receipts}

static func from_data(d: Dictionary) -> MatchState:
	var state := MatchState.new()
	for key in state.to_data():
		if d.has(key): state.set(key, d[key])
	return state

func clone() -> MatchState:
	return from_data(to_data().duplicate(true))

func is_terminal() -> bool:
	return not terminal_reason.is_empty()
