class_name DuelAssertions
extends RefCounted

var failures: Array[String] = []
var checks: int = 0

func equal(actual: Variant, expected: Variant, message: String) -> void:
	checks += 1
	if actual != expected: failures.append("%s: expected %s, got %s" % [message, str(expected), str(actual)])

func truth(value: bool, message: String) -> void:
	equal(value, true, message)
