class_name ActionLedger
extends RefCounted

# One ledger per authenticated remote slot. Reset only at a new round boundary.
const RESULT_CAP := 2048
const PENDING_CAP := 16
var round_number: int = 0
var highwater: int = 0
var pending: Dictionary = {}
var results: Dictionary = {}

func reset(number: int) -> void:
	round_number = number
	highwater = 0
	pending.clear()
	results.clear()

func begin(request_round: int, action_id: int, tick: int, inventory_revision: int) -> Dictionary:
	if request_round != round_number: return {"execute": false, "result": _result(request_round, action_id, 2, inventory_revision, tick, tick)}
	if results.has(action_id): return {"execute": false, "result": results[action_id].duplicate(true)}
	if pending.has(action_id): return {"execute": false, "pending": true}
	if action_id <= highwater: return {"execute": false, "result": _result(round_number, action_id, 12, inventory_revision, tick, tick)}
	highwater = action_id
	if pending.size() >= PENDING_CAP:
		var result := _result(round_number, action_id, 8, inventory_revision, tick, tick)
		_cache(action_id, result)
		return {"execute": false, "result": result.duplicate(true)}
	pending[action_id] = tick
	return {"execute": true}

func complete(action_id: int, code: int, inventory_revision: int, tick: int) -> DuelResult:
	if results.has(action_id): return DuelResult.success(results[action_id].duplicate(true))
	if not pending.has(action_id): return DuelResult.failure("UNKNOWN_ACTION")
	if code < 0 or code > 12 or tick < int(pending[action_id]): return DuelResult.failure("INVALID_RESULT")
	var result := _result(round_number, action_id, code, inventory_revision, int(pending[action_id]), tick)
	pending.erase(action_id)
	_cache(action_id, result)
	return DuelResult.success(result.duplicate(true))

func _cache(action_id: int, result: Dictionary) -> void:
	results[action_id] = result
	if results.size() > RESULT_CAP: results.erase(results.keys()[0])

static func _result(number: int, id: int, code: int, revision: int, accepted: int, completed: int) -> Dictionary:
	return {"round": number, "actionId": id, "resultCode": code, "inventoryRevision": revision, "acceptedTick": accepted, "completeTick": completed}
