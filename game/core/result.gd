class_name DuelResult
extends RefCounted

var ok: bool = false
var value: Variant
var error_code: String = ""
var details: String = ""

static func success(data: Variant = null) -> DuelResult:
	var r := DuelResult.new()
	r.ok = true
	r.value = data
	return r

static func failure(code: String, detail: String = "") -> DuelResult:
	var r := DuelResult.new()
	r.error_code = code
	r.details = detail
	return r
