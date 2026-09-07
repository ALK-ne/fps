class_name DuelIds
extends RefCounted

static func random_bytes(count: int) -> PackedByteArray:
	return Crypto.new().generate_random_bytes(count)

static func digest(data: PackedByteArray) -> PackedByteArray:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(data)
	return context.finish()

static func recovery_id(match_id: PackedByteArray, epoch: int) -> PackedByteArray:
	var bytes := match_id.duplicate()
	var encoded := PackedByteArray()
	encoded.resize(4)
	encoded.encode_u32(0, epoch)
	bytes.append_array(encoded)
	bytes.append_array("recovery".to_utf8_buffer())
	return digest(bytes).slice(0, 16)
