class_name MessageCodec
extends RefCounted

# Only local generated schemas are interpreted. Network bytes never supply types.
static var schema: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/wire_schema.json"))
const WIDTHS := {"u8": 1, "i8": 1, "u16": 2, "i16": 2, "u32": 4, "i32": 4, "u64": 8, "f32": 4, "b16": 16, "b32": 32}
const RANGES := {"u8": [0, 255], "i8": [-128, 127], "u16": [0, 65535], "i16": [-32768, 32767], "u32": [0, 4294967295], "i32": [-2147483648, 2147483647]}
var stream := StreamPeerBuffer.new()
var error: String = ""

static func _enum_has(values: Array, value: Variant) -> bool:
	if not value is int: return false
	for candidate in values:
		if int(candidate) == value: return true
	return false

static func _valid_utf8(bytes: PackedByteArray) -> bool:
	var index := 0
	while index < bytes.size():
		var lead := int(bytes[index])
		if lead < 128:
			index += 1
			continue
		var width := 2 if lead >= 0xc2 and lead <= 0xdf else (3 if lead >= 0xe0 and lead <= 0xef else (4 if lead >= 0xf0 and lead <= 0xf4 else 0))
		if width == 0 or index + width > bytes.size(): return false
		for offset in range(1, width):
			if bytes[index + offset] < 0x80 or bytes[index + offset] > 0xbf: return false
		var second := int(bytes[index + 1])
		if (lead == 0xe0 and second < 0xa0) or (lead == 0xed and second >= 0xa0) or (lead == 0xf0 and second < 0x90) or (lead == 0xf4 and second > 0x8f): return false
		index += width
	return true

static func encode(kind: int, value: Dictionary, event: bool = false) -> DuelResult:
	var types: Dictionary = schema.events if event else schema.messages
	if not types.has(str(kind)): return DuelResult.failure("UNKNOWN_TYPE")
	var codec := MessageCodec.new()
	codec._write(types[str(kind)], value)
	if not codec.error.is_empty(): return DuelResult.failure(codec.error)
	return DuelResult.success(codec.stream.data_array)

static func decode(kind: int, bytes: PackedByteArray, event: bool = false) -> DuelResult:
	var types: Dictionary = schema.events if event else schema.messages
	if not types.has(str(kind)): return DuelResult.failure("UNKNOWN_TYPE")
	if bytes.size() > 32768: return DuelResult.failure("SIZE_LIMIT")
	var codec := MessageCodec.new()
	codec.stream.data_array = bytes
	var value: Variant = codec._read(types[str(kind)])
	if not codec.error.is_empty(): return DuelResult.failure(codec.error)
	if codec.stream.get_available_bytes() != 0: return DuelResult.failure("TRAILING_BYTES")
	return DuelResult.success(value)

func _need(count: int) -> bool:
	if not error.is_empty(): return false
	if stream.get_available_bytes() < count:
		error = "TRUNCATED"
		return false
	return true

func _read(type: Variant) -> Variant:
	if not error.is_empty(): return null
	if type is String:
		if not _need(WIDTHS[type]): return null
		if type.begins_with("b"): return stream.get_data(WIDTHS[type])[1]
		var value: Variant = stream.call("get_" + type.replace("f32", "float").trim_prefix("i"))
		if type == "f32" and not is_finite(value): error = "NON_FINITE"
		return value
	if type.has("fields"):
		var value: Dictionary = {}
		for field in type.fields:
			value[field[0]] = _read(field[1])
			if not error.is_empty(): return null
		return value
	if type.has("enum"):
		var value: Variant = _read(type.enum)
		if error.is_empty() and not _enum_has(type.values, value): error = "UNKNOWN_ENUM"
		return value
	if type.has("tagged"):
		var tag: Variant = _read("u8")
		var size: Variant = _read("u16")
		if not error.is_empty(): return null
		if not type.tagged.has(str(tag)):
			error = "UNKNOWN_ENUM"
			return null
		if not _need(size): return null
		var child := MessageCodec.new()
		child.stream.data_array = stream.get_data(size)[1]
		var payload: Variant = child._read(type.tagged[str(tag)])
		if not child.error.is_empty(): error = child.error
		elif child.stream.get_available_bytes() != 0: error = "TRAILING_BYTES"
		return {"type": tag, "payload": payload}
	var count: Variant = _read("u16")
	if not error.is_empty(): return null
	var limit: int = type.get("max", type.get("bytes", type.get("utf8", 0)))
	if count < int(type.get("min", 0)) or count > limit:
		error = "COUNT_LIMIT"
		return null
	if type.has("array"):
		var values: Array = []
		for index in count:
			values.append(_read(type.array))
			if not error.is_empty(): return null
		return values
	if not _need(count): return null
	var bytes: PackedByteArray = stream.get_data(count)[1]
	if type.has("bytes"): return bytes
	if not _valid_utf8(bytes):
		error = "INVALID_UTF8"
		return null
	return bytes.get_string_from_utf8()

func _write(type: Variant, value: Variant) -> void:
	if not error.is_empty(): return
	if type is String:
		if type.begins_with("b"):
			if not value is PackedByteArray or value.size() != WIDTHS[type]: error = "INVALID_BYTES"
			else: stream.put_data(value)
		elif type == "f32":
			if not (value is int or value is float) or not is_finite(float(value)) or absf(float(value)) > 3.4028234663852886e38: error = "NON_FINITE"
			else: stream.put_float(value)
		elif not value is int: error = "INVALID_INTEGER"
		elif RANGES.has(type) and (value < RANGES[type][0] or value > RANGES[type][1]): error = "INTEGER_RANGE"
		else:
			# u64 uses the complete signed int64 bit pattern, without float conversion.
			stream.call("put_" + type.trim_prefix("i"), value)
	elif type.has("fields"):
		if not value is Dictionary or value.size() != type.fields.size():
			error = "INVALID_FIELDS"
			return
		for field in type.fields:
			if not value.has(field[0]):
				error = "INVALID_FIELDS"
				return
			_write(field[1], value[field[0]])
	elif type.has("enum"):
		if not _enum_has(type.values, value): error = "UNKNOWN_ENUM"
		else: _write(type.enum, value)
	elif type.has("tagged"):
		if not value is Dictionary or value.size() != 2 or not value.get("type") is int or not value.has("payload") or not type.tagged.has(str(value.type)):
			error = "UNKNOWN_ENUM"
			return
		var child := MessageCodec.new()
		child._write(type.tagged[str(value.type)], value.payload)
		if not child.error.is_empty():
			error = child.error
			return
		_write("u8", value.type)
		_write("u16", child.stream.data_array.size())
		stream.put_data(child.stream.data_array)
	else:
		var array_type: bool = type.has("array")
		if (array_type and not value is Array) or (type.has("bytes") and not value is PackedByteArray) or (type.has("utf8") and not value is String):
			error = "INVALID_TYPE"
			return
		var data: Variant = value.to_utf8_buffer() if type.has("utf8") else value
		var limit: int = type.get("max", type.get("bytes", type.get("utf8", 0)))
		if data.size() < int(type.get("min", 0)) or data.size() > limit:
			error = "COUNT_LIMIT"
			return
		_write("u16", data.size())
		if array_type:
			for item in data: _write(type.array, item)
		else: stream.put_data(data)
	if stream.get_position() > 32768: error = "SIZE_LIMIT"
