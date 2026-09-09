extends RefCounted

func test_approved_abort_is_terminal_without_score_change(a: DuelAssertions) -> void:
	var reducer := MatchReducer.new()
	var state := MatchState.new()
	state.match_id = DuelIds.random_bytes(16)
	state.rule_hash = DuelIds.random_bytes(32)
	state.round = 3
	state.round_status = "OPEN"
	state.scores = [2, 0]
	state.epoch_high_water = 1
	var event := MatchEvent.make(5, {"old_epoch": 1, "new_epoch": 2, "recovery_id": "approved-abort", "disposition": 3, "offender": -1, "round": 3})
	var applied := reducer.apply(state, event)
	a.truth(applied.ok, "approved policy accepts unknown-responsibility abort")
	a.equal(applied.value.scores, [2, 0], "scores unchanged")
	a.equal(applied.value.match_winner, -1, "no invented winner")
	a.truth(applied.value.is_terminal(), "old match closed")
	a.equal(applied.value.terminal_reason, "RESPONSIBILITY_UNKNOWN", "reason retained")
	var repeat := reducer.apply(applied.value, event)
	a.truth(repeat.ok, "duplicate resolution idempotent")
	a.equal(repeat.value.to_data(), applied.value.to_data(), "no second mutation")
	event.payload.offender = 0
	a.truth(not reducer.apply(state, event).ok, "known offender cannot be disguised as unknown abort")
	var config := GameConfig.new()
	a.truth(config.load_data().ok, "approved policy part of validated rules")
	a.equal(config.rules.recoveryPolicy, "abort-v1", "rules hash includes approved policy")
