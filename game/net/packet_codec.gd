class_name PacketCodec
extends RefCounted

# Crypto construction initializes the platform backend. Reuse it for the
# per-packet HMAC and constant-time comparison on the main thread.
static var crypto := Crypto.new()

var outgoing: Array = [0, 0, 0, 0]
var incoming: Array = [-1, -1, -1, -1]
var received_sequences: Array[PackedInt64Array] = []
var fragments: Dictionary = {}
var next_message: int = 1

func _init() -> void:
	for channel in 4:
		var window := PackedInt64Array()
		window.resize(1024)
		received_sequences.append(window)

static func mac(key: PackedByteArray, bytes: PackedByteArray) -> PackedByteArray:
	return crypto.hmac_digest(HashingContext.HASH_SHA256, key, bytes)

func encode(kind: int, payload: PackedByteArray, match_id: PackedByteArray, epoch: int, slot: int, channel: int, key: PackedByteArray) -> Array:
	var packets: Array = []
	if payload.size() > 32768 or match_id.size() != 16 or key.size() != 32 or channel < 0 or channel > 3: return packets
	if payload.size() <= 1120: packets.append(_packet(kind, payload, match_id, epoch, slot, channel, key, 0))
	else:
		var count := int(ceil(payload.size() / 1104.0))
		for i in count:
			var s := StreamPeerBuffer.new()
			s.put_u64(next_message)
			s.put_u16(i)
			s.put_u16(count)
			s.put_u32(payload.size())
			s.put_data(payload.slice(i * 1104, mini((i + 1) * 1104, payload.size())))
			packets.append(_packet(kind, s.data_array, match_id, epoch, slot, channel, key, 1))
		next_message += 1
	return packets

func _packet(kind: int, payload: PackedByteArray, match_id: PackedByteArray, epoch: int, slot: int, channel: int, key: PackedByteArray, flags: int) -> PackedByteArray:
	var s := StreamPeerBuffer.new()
	s.put_data("ADU1".to_ascii_buffer())
	s.put_u16(2)
	s.put_u16(kind)
	s.put_data(match_id)
	s.put_u32(epoch)
	outgoing[channel] += 1
	s.put_u64(outgoing[channel])
	s.put_u8(slot)
	s.put_u8(channel)
	s.put_u16(flags)
	s.put_u32(payload.size())
	s.put_u32(0)
	s.put_data(payload)
	var bytes := s.data_array
	bytes.append_array(mac(key, bytes))
	return bytes

func decode(bytes: PackedByteArray, key: PackedByteArray, match_id: PackedByteArray, channel: int, expected_epoch: int = -1) -> DuelResult:
	if bytes.size() < 80 or bytes.size() > 1200 or key.size() != 32 or channel not in [0, 1, 2, 3]: return DuelResult.failure("INVALID_PACKET")
	if bytes.slice(0, 4) != "ADU1".to_ascii_buffer() or bytes.decode_u16(4) != 2: return DuelResult.failure("VERSION_MISMATCH")
	var body := bytes.slice(0, bytes.size() - 32)
	if not crypto.constant_time_compare(mac(key, body), bytes.slice(bytes.size() - 32)): return DuelResult.failure("AUTH_FAILED")
	if body.slice(8, 24) != match_id: return DuelResult.failure("MATCH_MISMATCH")
	var epoch := body.decode_u32(24)
	var seq := body.decode_u64(28)
	var flags := body.decode_u16(38)
	if expected_epoch >= 0 and epoch != expected_epoch: return DuelResult.failure("STALE_EPOCH")
	if body[37] != channel or body[36] > 1 or flags > 1 or body.decode_u32(44) != 0 or body.decode_u32(40) != body.size() - 48: return DuelResult.failure("INVALID_PACKET")
	if seq < 1 or int(incoming[channel]) - seq >= 1024: return DuelResult.failure("REPLAY")
	var index := seq % 1024
	if received_sequences[channel][index] == seq: return DuelResult.failure("REPLAY")
	received_sequences[channel][index] = seq
	incoming[channel] = maxi(int(incoming[channel]), seq)
	var payload := body.slice(48)
	var kind := body.decode_u16(6)
	if flags == 1:
		var r := _assemble(kind, payload)
		if not r.ok: return r
		payload = r.value
	return DuelResult.success({"kind": kind, "epoch": epoch, "slot": int(body[36]), "payload": payload})

func _assemble(kind: int, payload: PackedByteArray) -> DuelResult:
	var now := Time.get_ticks_msec()
	for id in fragments.keys():
		if now - int(fragments[id].created) >= 3000: fragments.erase(id)
	if payload.size() < 17: return DuelResult.failure("INVALID_FRAGMENT")
	var id := payload.decode_u64(0)
	var index := payload.decode_u16(8)
	var count := payload.decode_u16(10)
	var size := payload.decode_u32(12)
	if size > 32768 or size <= 1120 or count != int(ceil(size / 1104.0)) or index >= count: return DuelResult.failure("INVALID_FRAGMENT")
	if not fragments.has(id):
		if fragments.size() >= 4: return DuelResult.failure("FRAGMENT_LIMIT")
		fragments[id] = {"created": now, "kind": kind, "count": count, "size": size, "parts": {}}
	var f: Dictionary = fragments[id]
	if f.kind != kind or f.count != count or f.size != size:
		fragments.erase(id)
		return DuelResult.failure("INVALID_FRAGMENT")
	var expected := mini(1104, size - index * 1104)
	if payload.size() - 16 != expected: return DuelResult.failure("INVALID_FRAGMENT")
	f.parts[index] = payload.slice(16)
	if f.parts.size() != count: return DuelResult.failure("FRAGMENT_PENDING")
	var bytes := PackedByteArray()
	for i in count: bytes.append_array(f.parts[i])
	fragments.erase(id)
	return DuelResult.success(bytes)
