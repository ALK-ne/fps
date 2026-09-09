class_name MatchReducer
extends RefCounted

static func armor_for_round(number: int) -> int:
	if number >= 12: return 125
	if number >= 8: return 100
	if number >= 4: return 75
	return 50

static func decide_round(players: Array, time_expired: bool) -> int:
	if players[0].hp_milli <= 0 and players[1].hp_milli <= 0: return -1
	if players[0].hp_milli <= 0: return 1
	if players[1].hp_milli <= 0: return 0
	if not time_expired: return -2
	var a: int = players[0].hp_milli + players[0].armor_milli
	var b: int = players[1].hp_milli + players[1].armor_milli
	return -1 if a == b else (0 if a > b else 1)

func apply(state: MatchState, event: MatchEvent) -> DuelResult:
	var s := state.clone()
	var p := event.payload
	var types = CanonicalCodec.Durable
	if event.type == types.RECOVERY_RESOLVED:
		if not _has(p, ["old_epoch", "new_epoch", "recovery_id", "disposition", "offender", "round"]): return _invalid()
		if int(p.old_epoch) <= s.last_recovery_epoch or s.recovery_receipts.has(str(p.recovery_id)):
			return DuelResult.success(s)
	if s.is_terminal(): return DuelResult.failure("TERMINAL")
	match event.type:
		types.MATCH_CREATED:
			if not _has(p, ["match_id", "rule_hash", "players", "epoch"]) or not s.match_id.is_empty(): return _invalid()
			if p.match_id.size() != 16 or p.rule_hash.size() != 32 or p.players.size() != 2: return _invalid()
			s.match_id = p.match_id
			s.rule_hash = p.rule_hash
			s.map_hash = p.get("map_hash", PackedByteArray())
			s.players = p.players.duplicate(true)
			s.epoch_high_water = p.epoch
		types.ROUND_PREPARED:
			if not p.has("round") or s.round_status not in ["UNOPENED", "CLOSED"] or p.round != s.round + 1: return _invalid()
			s.prepared_round = p.round
			s.first_slot = p.get("first_slot", 0)
			s.round_status = "PREPARED"
			s.phase = CanonicalCodec.Phase.OPENING
		types.ROUND_ACTIVATED:
			if not p.has("round") or s.round_status != "PREPARED" or p.round != s.prepared_round: return _invalid()
			s.round = s.prepared_round
			s.prepared_round = 0
			s.round_status = "OPEN"
		types.ROUND_CLOSED:
			if not _has(p, ["round", "winner"]) or s.round_status != "OPEN" or p.round != s.round or p.winner not in [-1, 0, 1]: return _invalid()
			_close(s, p.winner)
		types.RECOVERY_RESOLVED:
			if p.old_epoch < 1 or p.new_epoch <= p.old_epoch or p.round != s.round: return _invalid()
			if p.disposition in [CanonicalCodec.Disposition.CLOSE, CanonicalCodec.Disposition.FORFEIT] and p.offender not in [0, 1]: return _invalid()
			match int(p.disposition):
				CanonicalCodec.Disposition.CLOSE:
					if s.round_status != "OPEN": return _invalid()
					_close(s, 1 - int(p.offender))
				CanonicalCodec.Disposition.KEEP:
					if s.round_status == "OPEN": return _invalid()
					s.prepared_round = 0
					s.round_status = "CLOSED" if s.round > 0 else "UNOPENED"
				CanonicalCodec.Disposition.FORFEIT:
					s.match_winner = 1 - int(p.offender)
					s.terminal_reason = "DISCONNECT_TIMEOUT"
					s.phase = CanonicalCodec.Phase.MATCH_RESULT
				CanonicalCodec.Disposition.ABORT:
					if p.offender != -1 or GameConfig.RECOVERY_POLICY != "abort-v1": return _invalid()
					s.match_winner = -1
					s.terminal_reason = "RESPONSIBILITY_UNKNOWN"
					s.phase = CanonicalCodec.Phase.MATCH_RESULT
				_: return _invalid()
			s.last_recovery_epoch = p.old_epoch
			s.epoch_high_water = maxi(s.epoch_high_water, p.new_epoch)
			s.recovery_receipts = {str(p.recovery_id): true}
		types.CHECKPOINT_INSTALLED:
			if s.round_status == "OPEN": return _invalid()
		_: return _invalid()
	return DuelResult.success(s)

func _close(s: MatchState, winner: int) -> void:
	s.previous_winner = winner
	s.round_status = "CLOSED"
	s.phase = CanonicalCodec.Phase.RESOLVING
	if winner >= 0:
		s.scores[winner] += 1
		if s.scores[winner] >= 10:
			s.match_winner = winner
			s.terminal_reason = "TEN_WINS"
			s.phase = CanonicalCodec.Phase.MATCH_RESULT

func _has(d: Dictionary, keys: Array) -> bool:
	for key in keys:
		if not d.has(key): return false
	return true

func _invalid() -> DuelResult:
	return DuelResult.failure("INVALID_TRANSITION")
