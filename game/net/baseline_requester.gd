class_name BaselineRequester
extends RefCounted

var request_id: int = 0
var active: bool = false
var sends: int = 0
var last_send: int = -1000
var reason: int = 0
var failed: bool = false

func reset() -> void:
	active = false
	sends = 0
	last_send = -1000
	failed = false

func request(value: int) -> void:
	if active or failed: return
	request_id += 1
	active = true
	sends = 0
	reason = value

func poll(number: int, sequence: int, tick: int, now: int) -> Dictionary:
	if not active or failed or now - last_send < (2000 if sends > 0 else 1000): return {}
	if sends == 3:
		failed = true
		return {}
	sends += 1
	last_send = now
	return {"round": number, "requestId": request_id, "knownEventSeq": sequence, "lastTick": tick, "reason": reason}

func complete() -> void:
	active = false
	sends = 0
