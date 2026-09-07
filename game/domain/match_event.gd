class_name MatchEvent
extends RefCounted

var type: int
var payload: Dictionary

static func make(kind: int, data: Dictionary) -> MatchEvent:
	var event := MatchEvent.new()
	event.type = kind
	event.payload = data.duplicate(true)
	return event
