class_name CanonicalCodec
extends RefCounted

enum Phase { LOBBY, OPENING, SELECTING_FIRST, SELECTING_SECOND, COUNTDOWN, FIGHTING, RESOLVING, SUSPENDED, MATCH_RESULT, CONFLICT, STORAGE_ERROR }
enum Action { IDLE, SWITCH, RELOAD, HEAL, GRENADE_READY, GRENADE_AIM, SWAP, VAULT }
enum Durable { MATCH_CREATED = 1, ROUND_PREPARED, ROUND_ACTIVATED, ROUND_CLOSED, RECOVERY_RESOLVED, CHECKPOINT_INSTALLED }
enum Disposition { CLOSE, KEEP, FORFEIT, ABORT }

# A bounded, deterministic value codec for local metadata. No Variant/object decoding.
# Wire envelopes and durable records have their own fixed field order.
static func encode(value: Variant) -> PackedByteArray:
	var stream := StreamPeerBuffer.new()
	write_value(stream, value)
	return stream.data_array

static func write_value(s: StreamPeerBuffer, v: Variant) -> void:
	match typeof(v):
		TYPE_NIL: s.put_u8(0)
		TYPE_BOOL:
			s.put_u8(1)
			s.put_u8(1 if v else 0)
		TYPE_INT:
			s.put_u8(2)
			s.put_64(v)
		TYPE_FLOAT:
			s.put_u8(3)
			s.put_double(v)
		TYPE_STRING:
			s.put_u8(4)
			var b: PackedByteArray = v.to_utf8_buffer()
			s.put_u16(b.size())
			s.put_data(b)
		TYPE_ARRAY, TYPE_PACKED_INT32_ARRAY:
			s.put_u8(5)
			s.put_u16(v.size())
			for item in v: write_value(s, item)
		TYPE_DICTIONARY:
			s.put_u8(6)
			var keys: Array[String] = []
			for key in v.keys(): keys.append(str(key))
			keys.sort()
			s.put_u16(keys.size())
			for key in keys:
				write_value(s, str(key))
				write_value(s, v[key])
		TYPE_PACKED_BYTE_ARRAY:
			s.put_u8(7)
			s.put_u16(v.size())
			s.put_data(v)
		TYPE_VECTOR3:
			s.put_u8(8)
			s.put_float(v.x)
			s.put_float(v.y)
			s.put_float(v.z)

static func decode(bytes: PackedByteArray, limit: int = 32768) -> DuelResult:
	if bytes.is_empty() or bytes.size() > limit:
		return DuelResult.failure("INVALID_SIZE")
	var s := StreamPeerBuffer.new()
	s.data_array = bytes
	var result := read_value(s, 0)
	if result.ok and s.get_available_bytes() != 0:
		return DuelResult.failure("TRAILING_BYTES")
	return result

static func read_value(s: StreamPeerBuffer, depth: int) -> DuelResult:
	if depth > 12 or s.get_available_bytes() < 1: return DuelResult.failure("TRUNCATED")
	var tag := s.get_u8()
	var needed := {0: 0, 1: 1, 2: 8, 3: 8, 4: 2, 5: 2, 6: 2, 7: 2, 8: 12}
	if not needed.has(tag) or s.get_available_bytes() < needed[tag]: return DuelResult.failure("INVALID_TAG")
	match tag:
		0: return DuelResult.success(null)
		1:
			var n := s.get_u8()
			return DuelResult.success(n == 1) if n < 2 else DuelResult.failure("INVALID_BOOL")
		2: return DuelResult.success(s.get_64())
		3:
			var n := s.get_double()
			return DuelResult.success(n) if is_finite(n) else DuelResult.failure("NONFINITE")
		4, 7:
			var n := s.get_u16()
			if n > s.get_available_bytes(): return DuelResult.failure("TRUNCATED")
			var b: PackedByteArray = s.get_data(n)[1]
			if tag == 7: return DuelResult.success(b)
			var t := b.get_string_from_utf8()
			return DuelResult.success(t) if t.to_utf8_buffer() == b else DuelResult.failure("INVALID_UTF8")
		5, 6:
			var n := s.get_u16()
			if n > 4096 or n > s.get_available_bytes(): return DuelResult.failure("INVALID_COUNT")
			var a: Array = []
			var d: Dictionary = {}
			var previous := ""
			for i in n:
				var r := read_value(s, depth + 1)
				if not r.ok: return r
				if tag == 5: a.append(r.value)
				else:
					if not r.value is String or (i > 0 and r.value <= previous): return DuelResult.failure("INVALID_KEY")
					previous = r.value
					var val := read_value(s, depth + 1)
					if not val.ok: return val
					d[previous] = val.value
			return DuelResult.success(a if tag == 5 else d)
		8:
			var v := Vector3(s.get_float(), s.get_float(), s.get_float())
			return DuelResult.success(v) if v.is_finite() else DuelResult.failure("NONFINITE")
	return DuelResult.failure("INVALID_TAG")
