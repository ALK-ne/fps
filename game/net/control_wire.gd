class_name ControlWire
extends RefCounted

# Adapts internal names only. All wire field order/limits are owned by MessageCodec.
const NAMES := {
	2: {"player": "hostPlayer", "boot": "hostBoot", "nonce": "hostNonce", "echo": "guestNonce"},
	3: {"host_nonce": "hostNonce", "guest_nonce": "guestNonce"},
	4: {"guest": "boundGuest", "seq": "hostLatestSeq"},
	5: {"sent": "sentMonoUs", "echo": "echoMonoUs", "tick": "lastServerTick"},
	23: {"first_slot": "firstSlot", "deadline_tick": "deadlineTick", "tick": "serverTick"},
	42: {"code": "invite"}
}
const TYPES := [1, 2, 3, 4, 5, 6, 10, 12, 20, 21, 22, 23, 24, 25, 26, 30, 31, 32, 33, 34, 35, 36, 37, 39, 40, 41, 42, 43, 44, 45, 50]

static func encode(kind: int, data: Dictionary, store: RecoveryStore = null) -> DuelResult:
	var wire := data.duplicate(true)
	var zero := PackedByteArray()
	zero.resize(32)
	match kind:
		32:
			wire = {"oldEpoch": data.old_epoch, "boot": data.boot, "oldHostBoot": data.old_host_boot, "oldGuestBoot": data.old_guest_boot,
				"seq": data.seq, "hash": data.hash if not data.hash.is_empty() else zero, "observedRound": store.state.round,
				"remainingMs": data.remaining if data.continuous else 0xffffffff, "continuous": int(data.continuous),
				"timerStatus": data.get("timer_status", 1 if data.continuous else 0), "resumeBlock": data.get("resume_block", 0), "offender": -1,
				"evidence": data.get("evidence", 1 if data.continuous else 0)}
		35:
			wire = {"recoveryId": data.recovery_id.hex_decode(), "oldEpoch": data.old_epoch, "newEpoch": data.new_epoch,
				"interruptedRound": data.round, "disposition": data.disposition, "offender": data.offender, "baseSeq": store.state.last_seq,
				"baseHash": data.base_hash, "remainingMs": data.remaining}
		36:
			wire = {"recoveryId": data.recovery_id.hex_decode(), "baseHash": data.base_hash, "remainingMs": data.remaining}
		31:
			wire.ackKind = int(data.get("ackKind", 0))
			wire.checkpointHash = data.get("checkpointHash", zero)
		33:
			wire = {"checkpointSeq": store.checkpoint_seq, "seq": int(data.from) - 1, "hash": store.hash_at(int(data.from) - 1)}
			if wire.seq == 0: wire.hash = zero
		34:
			if data.has("record"):
				var record: PackedByteArray = data.record
				if record.size() < 128: return DuelResult.failure("INVALID_HISTORY")
				wire = {"done": 0, "seq": record.decode_u64(50), "hash": record.slice(record.size() - 32), "record": record}
			else: wire = {"done": 1, "seq": data.seq, "hash": data.hash, "record": PackedByteArray()}
		37:
			wire = {"seq": store.state.last_seq, "hash": store.state.last_hash, "checkpointHash": DuelIds.digest(data.checkpoint), "stateBytes": data.checkpoint}
	for source in NAMES.get(kind, {}):
		wire[NAMES[kind][source]] = wire[source]
		wire.erase(source)
	if kind == 5:
		wire.sentMonoUs *= 1000
		wire.echoMonoUs *= 1000
	elif kind == 4 and wire.hostLatestSeq == 0 and wire.hash.is_empty():
		wire.hash = PackedByteArray()
		wire.hash.resize(32)
	elif kind == 23:
		wire.spawn0 = wire.selected_spawn[0]
		wire.spawn1 = wire.selected_spawn[1]
		wire.erase("selected_spawn")
	elif kind in [6, 40]: wire.ready = int(wire.ready)
	elif kind == 41:
		wire.oldEpoch = wire.old_epoch
		wire.erase("old_epoch")
	return MessageCodec.encode(kind, wire)

static func decode(kind: int, bytes: PackedByteArray) -> DuelResult:
	if kind == 24 and (bytes.size() < 32 or DuelIds.digest(bytes.slice(0, bytes.size() - 32)) != bytes.slice(bytes.size() - 32)): return DuelResult.failure("INVALID_BASELINE_HASH")
	var decoded := MessageCodec.decode(kind, bytes)
	if not decoded.ok: return decoded
	var wire: Dictionary = decoded.value
	var semantic := MessagePolicy.decoded(kind, wire)
	if not semantic.ok: return semantic
	match kind:
		32:
			return DuelResult.success({"old_epoch": wire.oldEpoch, "boot": wire.boot, "old_host_boot": wire.oldHostBoot, "old_guest_boot": wire.oldGuestBoot,
				"seq": wire.seq, "hash": wire.hash, "round": wire.observedRound, "remaining": wire.remainingMs, "continuous": bool(wire.continuous),
				"terminal": wire.resumeBlock != 0, "timer_status": wire.timerStatus, "evidence": wire.evidence})
		35:
			return DuelResult.success({"recovery_id": wire.recoveryId.hex_encode(), "old_epoch": wire.oldEpoch, "new_epoch": wire.newEpoch,
				"round": wire.interruptedRound, "disposition": wire.disposition, "offender": wire.offender, "base_seq": wire.baseSeq,
				"base_hash": wire.baseHash, "remaining": wire.remainingMs})
		36: return DuelResult.success({"recovery_id": wire.recoveryId.hex_encode(), "base_hash": wire.baseHash, "remaining": wire.remainingMs})
		33: return DuelResult.success({"from": wire.seq + 1, "checkpoint_seq": wire.checkpointSeq, "hash": wire.hash})
		34:
			if wire.done == 1: return DuelResult.success({"done": true, "seq": wire.seq, "hash": wire.hash})
			if wire.record.decode_u64(50) != wire.seq or wire.record.slice(wire.record.size() - 32) != wire.hash: return DuelResult.failure("INVALID_HISTORY")
			return DuelResult.success({"record": wire.record})
		37:
			if DuelIds.digest(wire.stateBytes) != wire.checkpointHash: return DuelResult.failure("STORE_CORRUPT")
			return DuelResult.success({"checkpoint": wire.stateBytes, "seq": wire.seq, "hash": wire.hash, "checkpointHash": wire.checkpointHash})
	if kind == 10:
		var sample: Dictionary = wire.samples.back()
		return DuelResult.success({"round": wire.round, "seq": sample.seq, "tick": sample.sampleTick,
			"x": sample.axisX / 32767.0, "y": sample.axisY / 32767.0, "yaw": sample.yaw, "pitch": sample.pitch, "held": sample.held, "actions": []})
	for source in NAMES.get(kind, {}):
		wire[source] = wire[NAMES[kind][source]]
		wire.erase(NAMES[kind][source])
	if kind == 5:
		wire.sent = int(wire.sent / 1000)
		wire.echo = int(wire.echo / 1000)
	elif kind == 23:
		wire.selected_spawn = [wire.spawn0, wire.spawn1]
		wire.erase("spawn0")
		wire.erase("spawn1")
	elif kind in [6, 40]: wire.ready = bool(wire.ready)
	elif kind == 41:
		wire.old_epoch = wire.oldEpoch
		wire.erase("oldEpoch")
	return DuelResult.success(wire)
