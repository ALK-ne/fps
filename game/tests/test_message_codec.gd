extends RefCounted

func _typed(type: Variant, value: Variant) -> Variant:
	if type is String:
		if type.begins_with("b"): return str(value).hex_decode()
		return float(value) if type == "f32" else int(value)
	if type.has("enum"): return int(value)
	if type.has("fields"):
		var out: Dictionary = {}
		for field in type.fields: out[field[0]] = _typed(field[1], value[field[0]])
		return out
	if type.has("array"):
		var out: Array = []
		for item in value: out.append(_typed(type.array, item))
		return out
	if type.has("bytes"): return str(value).hex_decode()
	if type.has("tagged"): return {"type": int(value.type), "payload": _typed(type.tagged[str(int(value.type))], value.payload)}
	return value

func test_all_normative_vectors(a: DuelAssertions) -> void:
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://../docs/implementation/wire-vectors.json"))
	a.equal(fixture.vectors.size(), 32, "all protocol messages covered")
	a.equal(fixture.events.size(), 9, "all events covered")
	for event in [false, true]:
		var types: Dictionary = MessageCodec.schema.events if event else MessageCodec.schema.messages
		for vector in fixture.events if event else fixture.vectors:
			var kind := int(vector.type)
			var expected: Variant = _typed(types[str(kind)], vector.value)
			var bytes: PackedByteArray = vector.normalHex.hex_decode()
			var decoded := MessageCodec.decode(kind, bytes, event)
			a.truth(decoded.ok, "decode normative type %d event=%s" % [kind, event])
			a.equal(decoded.value, expected, "decoded fields match independent vector")
			var encoded := MessageCodec.encode(kind, expected, event)
			a.truth(encoded.ok, "encode normative payload")
			a.equal(encoded.value, bytes, "exact normative little endian bytes")
			for length in bytes.size():
				a.truth(not MessageCodec.decode(kind, bytes.slice(0, length), event).ok, "every truncated prefix rejected")
			a.equal(MessageCodec.decode(kind, bytes + PackedByteArray([0]), event).error_code, "TRAILING_BYTES", "trailing byte rejected")
	a.equal(MessageCodec.decode(999, PackedByteArray()).error_code, "UNKNOWN_TYPE", "unknown type rejected")
	a.equal(MessageCodec.decode(11, PackedByteArray()).error_code, "TRUNCATED", "empty snapshot rejected")

func test_numeric_lengths_and_events(a: DuelAssertions) -> void:
	var value := {"round": 4294967295, "actionId": -1, "inputSeq": 9223372036854775807, "sampleTick": 0, "actionType": 0, "targetId": 0, "expectedRevision": 0, "argument": -2147483648}
	var result := MessageCodec.encode(20, value)
	a.truth(result.ok, "all unsigned64 bit patterns and signed32 minimum supported")
	a.equal(MessageCodec.decode(20, result.value).value, value, "large integers never converted through floating point")
	value.round = 4294967296
	a.equal(MessageCodec.encode(20, value).error_code, "INTEGER_RANGE", "u32 overflow rejected")
	value.round = 1
	value.actionType = 255
	a.equal(MessageCodec.encode(20, value).error_code, "UNKNOWN_ENUM", "unknown action rejected")
	value.actionType = 0
	value.extra = 0
	a.equal(MessageCodec.encode(20, value).error_code, "INVALID_FIELDS", "extra fields rejected")
	a.equal(MessageCodec.decode(10, PackedByteArray([1, 0, 0, 0, 4, 0])).error_code, "COUNT_LIMIT", "input count checked before allocation")
	var sample := {"seq": 1, "sampleTick": 0, "axisX": -32767, "axisY": 32767, "yaw": 0.0, "pitch": 0.0, "held": 0}
	for number in [NAN, INF, -INF, 1e100]:
		sample.yaw = number
		a.equal(MessageCodec.encode(10, {"round": 1, "samples": [sample]}).error_code, "NON_FINITE", "invalid float rejected before transmission")
	sample.yaw = 0.0
	var bytes: PackedByteArray = MessageCodec.encode(10, {"round": 1, "samples": [sample]}).value
	bytes.encode_u32(26, 0x7f800000)
	a.equal(MessageCodec.decode(10, bytes).error_code, "NON_FINITE", "received infinity rejected")
	var event := {"type": 8, "payload": {"slot": 1}}
	var batch := {"round": 1, "firstEventSeq": 1, "serverTick": 2, "events": [event]}
	bytes = MessageCodec.encode(22, batch).value
	a.equal(MessageCodec.decode(22, bytes).value, batch, "tagged event batch round trip")
	bytes.encode_u16(23, 2)
	bytes.append(0)
	a.equal(MessageCodec.decode(22, bytes).error_code, "TRAILING_BYTES", "event payload length cannot hide extra bytes")
	a.equal(MessageCodec.encode(42, {"invite": "あいう"}).value, PackedByteArray([9,0]) + "あいう".to_utf8_buffer(), "UTF8 length uses bytes")
	for invalid in [[0xc0, 0x80], [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80], [0xe3, 0x81], [0x80]]:
		a.equal(MessageCodec.decode(42, PackedByteArray([invalid.size(), 0]) + PackedByteArray(invalid)).error_code, "INVALID_UTF8", "overlong, surrogate, overflow, truncated or isolated UTF8 rejected")
	for valid in ["ASCII", "日本語", "😀", "�"]:
		a.equal(MessageCodec.decode(42, MessageCodec.encode(42, {"invite": valid}).value).value.invite, valid, "valid Unicode scalar sequences preserved")
