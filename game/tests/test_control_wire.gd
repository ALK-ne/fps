extends RefCounted

func test_control_adapters(a: DuelAssertions) -> void:
	var zero := PackedByteArray()
	zero.resize(32)
	var id := PackedByteArray()
	id.resize(16)
	var cases := {
		1: {"player": id, "boot": id, "nonce": zero, "rules": zero, "map": zero},
		2: {"player": id, "boot": id, "nonce": zero, "echo": zero, "epoch": 1},
		3: {"host_nonce": zero, "guest_nonce": zero},
		4: {"epoch": 1, "guest": id, "seq": 0, "hash": zero},
		5: {"sent": 123456, "echo": 123450, "tick": 42},
		6: {"ready": true},
		23: {"round": 1, "revision": 3, "phase": 4, "first_slot": 0, "selected_spawn": [0, 3], "deadline_tick": 600, "tick": 420},
		40: {"ready": true}, 41: {"reason": 2, "old_epoch": 1}, 42: {"code": "AD2:test"},
		50: {"round": 1, "requestId": 3, "revision": 2, "spawn": 3}}
	for kind in cases:
		var encoded := ControlWire.encode(kind, cases[kind])
		a.truth(encoded.ok, "control encoding %d" % kind)
		a.equal(ControlWire.decode(kind, encoded.value).value, cases[kind], "control model round trip %d" % kind)
	cases[4].hash = PackedByteArray()
	a.truth(ControlWire.encode(4, cases[4]).ok, "new match zero hash before first durable record")
	var sample := {"seq": 7, "sampleTick": 100, "axisX": -32767, "axisY": 32767, "yaw": 0.0, "pitch": 0.0, "held": 16}
	var encoded := ControlWire.encode(10, {"round": 1, "samples": [sample]})
	var decoded := ControlWire.decode(10, encoded.value)
	a.truth(decoded.ok, "typed input decoded")
	a.equal([decoded.value.x, decoded.value.y, decoded.value.held], [-1.0, 1.0, 16], "axes and hold preserved")
	a.equal(decoded.value.actions, [], "edge actions are not in unreliable input")

func test_protocol_version_rejection(a: DuelAssertions) -> void:
	var config := GameConfig.new()
	config.load_data()
	a.equal(DuelAuth.parse_invitation("AD1:old", config).error_code, "VERSION_MISMATCH", "old invitation explicitly refused")
	var key := DuelIds.random_bytes(32)
	var mid := DuelIds.random_bytes(16)
	var packet: PackedByteArray = PacketCodec.new().encode(6, PackedByteArray([1]), mid, 1, 0, 0, key)[0]
	a.equal(packet.decode_u16(4), 2, "wire advertises protocol 2")
	packet.encode_u16(4, 1)
	a.equal(PacketCodec.new().decode(packet, key, mid, 0).error_code, "VERSION_MISMATCH", "old version rejected before MAC verification")
