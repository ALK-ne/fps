class_name RecoveryStatus
extends RefCounted

const UNKNOWN_REMAINING := 0xffffffff
const FIELDS := ["noticeId", "oldEpoch", "observerBoot", "seq", "hash", "observedRound", "timerStatus", "resumeBlock", "resultStatus", "winner", "evidence", "offender", "observationHash"]

static func notice_id(mid: PackedByteArray, old_epoch: int, result: int, observation_hash: PackedByteArray) -> PackedByteArray:
	var stream := StreamPeerBuffer.new()
	stream.put_data(mid)
	stream.put_u32(old_epoch)
	stream.put_u8(result)
	stream.put_data(observation_hash)
	return DuelIds.digest(stream.data_array).slice(0, 16)

static func create(state: MatchState, old_epoch: int, boot: PackedByteArray, observation: Dictionary, reason: String, offender: int) -> Dictionary:
	var expired := reason in ["RECOVERY_EXPIRED", "RECOVERY_ACK_TIMEOUT"]
	if state.terminal_reason == "DISCONNECT_TIMEOUT":
		expired = true
		offender = 1 - state.match_winner
	var uncertain := reason == "CLOCK_UNCERTAIN"
	var block := 1 if expired else (6 if uncertain else (4 if reason.begins_with("STORE") else 3))
	var result := (1 if offender >= 0 else 2) if expired else 0
	if reason == "RECOVERY_ACK_TIMEOUT": result = 0
	var evidence := (17 if expired else 0) | (2 if offender >= 0 else 0)
	if state.is_terminal():
		block = 1
		result = {"TEN_WINS": 3, "DISCONNECT_TIMEOUT": 1, "RESPONSIBILITY_UNKNOWN": 2}.get(state.terminal_reason, 0)
		evidence |= 32
	var hash_value := state.last_hash.duplicate()
	if hash_value.is_empty(): hash_value.resize(32)
	var observation_hash := DuelIds.digest(CanonicalCodec.encode(observation))
	return {"noticeId": notice_id(state.match_id, old_epoch, result, observation_hash), "oldEpoch": old_epoch, "observerBoot": boot,
		"seq": state.last_seq, "hash": hash_value, "observedRound": state.round, "timerStatus": 2 if expired else (3 if uncertain else 0),
		"resumeBlock": block, "resultStatus": result, "winner": state.match_winner if state.is_terminal() else (1 - offender if result == 1 else -1),
		"evidence": evidence, "offender": offender, "observationHash": observation_hash}

static func validate(value: Dictionary, state: MatchState) -> bool:
	if not StoreSchema.exact(value, FIELDS): return false
	var message := value.duplicate(true)
	message.requestId = PackedByteArray()
	message.requestId.resize(16)
	var encoded := MessageCodec.encode(44, message)
	if not encoded.ok or not MessagePolicy.decoded(44, message).ok: return false
	if value.noticeId != notice_id(state.match_id, value.oldEpoch, value.resultStatus, value.observationHash): return false
	if value.seq != state.last_seq or (value.seq > 0 and value.hash != state.last_hash): return false
	if value.observedRound != state.round: return false
	match int(value.resultStatus):
		0: return value.winner == -1
		1: return value.offender in [0, 1] and value.winner == 1 - value.offender and value.timerStatus == 2 and value.evidence & 16 and value.evidence & 14
		2: return value.winner == -1 and GameConfig.RECOVERY_POLICY == "abort-v1"
		3: return state.terminal_reason == "TEN_WINS" and value.winner == state.match_winner
	return false

static func message(value: Dictionary) -> String:
	if value.is_empty(): return "相手に確認できず、再開できません。状態を再確認できます。"
	match int(value.resumeBlock):
		3: return "保存履歴が一致しないため再開できません。記録を保持しています。"
		4: return "記録を保存・読み込みできません。"
		6: return "時計の連続性を確認できないため再開できません。勝敗は未確定です。"
	match int(value.resultStatus):
		1: return "復帰期限が過ぎました。切断による試合終了です。"
		2: return "勝者なし・得点不変で試合を中断しました。"
		3: return "10勝による試合終了です。"
	return "復帰条件を確認できないため停止しています。勝敗は未確定です。"
