class_name DuelAuth
extends RefCounted

static func invitation(data: Dictionary) -> String:
	return "AD1:" + Marshalls.raw_to_base64(JSON.stringify(data).to_utf8_buffer()).replace("+", "-").replace("/", "_").trim_suffix("=").trim_suffix("=")

static func parse_invitation(code: String, config: GameConfig) -> DuelResult:
	if code.length() > 2048 or not code.begins_with("AD1:"): return DuelResult.failure("INVALID_INVITATION")
	var text := code.substr(4).replace("-", "+").replace("_", "/")
	while text.length() % 4: text += "="
	var data: Variant = JSON.parse_string(Marshalls.base64_to_raw(text).get_string_from_utf8())
	if not data is Dictionary: return DuelResult.failure("INVALID_INVITATION")
	for key in ["v", "match", "host", "port", "secret", "rules", "map"]:
		if not data.has(key): return DuelResult.failure("INVALID_INVITATION")
	if data.v != 1 or not data.host is String or data.host.length() > 253 or data.host.is_empty() or int(data.port) < 1024 or int(data.port) > 65535: return DuelResult.failure("INVALID_INVITATION")
	for pair in [["match", 32], ["secret", 64], ["rules", 64], ["map", 64]]:
		if not data[pair[0]] is String or data[pair[0]].length() != pair[1] or not str(data[pair[0]]).is_valid_hex_number(false): return DuelResult.failure("INVALID_INVITATION")
	if data.rules != config.rules_hash.hex_encode() or data.map != config.map_hash.hex_encode(): return DuelResult.failure("VERSION_MISMATCH")
	return DuelResult.success(data)

static func session_key(secret: PackedByteArray, match_id: PackedByteArray, epoch: int, host_nonce: PackedByteArray, guest_nonce: PackedByteArray, host_boot: PackedByteArray, guest_boot: PackedByteArray) -> PackedByteArray:
	var s := StreamPeerBuffer.new()
	s.put_data("AD1-session".to_ascii_buffer())
	s.put_data(match_id)
	s.put_u32(epoch)
	for value in [host_nonce, guest_nonce, host_boot, guest_boot]: s.put_data(value)
	return PacketCodec.mac(secret, s.data_array)
