extends RefCounted

func test_snapshot(a: DuelAssertions) -> void:
	var p := PlayerState.new()
	var q := PlayerState.new()
	q.slot = 1
	var data := {"round": 1, "tick": 123, "players": [Replication.player_data(p), Replication.player_data(q)]}
	var bytes := SnapshotCodec.encode(data)
	a.equal(bytes.size(), 278, "single packet snapshot")
	var r := SnapshotCodec.decode(bytes)
	a.truth(r.ok, "snapshot decode")
	a.equal(SnapshotCodec.encode(r.value), bytes, "snapshot roundtrip")

func test_packet_authentication(a: DuelAssertions) -> void:
	var sender := PacketCodec.new()
	var receiver := PacketCodec.new()
	var key := DuelIds.random_bytes(32)
	var mid := DuelIds.random_bytes(16)
	var data := CanonicalCodec.encode({"hello": "test"})
	var packet: PackedByteArray = sender.encode(1, data, mid, 1, 0, 0, key)[0]
	a.truth(receiver.decode(packet, key, mid, 0, 1).ok, "valid HMAC")
	a.truth(not receiver.decode(packet, key, mid, 0, 1).ok, "replay rejected")
	packet[48] ^= 1
	a.truth(not PacketCodec.new().decode(packet, key, mid, 0, 1).ok, "tampering rejected")

func test_fragments(a: DuelAssertions) -> void:
	var sender := PacketCodec.new()
	var receiver := PacketCodec.new()
	var key := DuelIds.random_bytes(32)
	var mid := DuelIds.random_bytes(16)
	var data := DuelIds.random_bytes(32768)
	var packets := sender.encode(24, data, mid, 2, 0, 3, key)
	var result: DuelResult
	for packet in packets:
		a.truth(packet.size() <= 1200, "MTU bound")
		result = receiver.decode(packet, key, mid, 3, 2)
	a.truth(result.ok, "all fragments assembled")
	a.equal(result.value.payload, data, "fragment bytes exact")

func test_real_enet(a: DuelAssertions) -> void:
	var host := ENetTransport.new()
	var guest := ENetTransport.new()
	var port := 29000 + int(DuelIds.random_bytes(2).decode_u16(0)) % 1000
	a.truth(host.listen({"bind": "127.0.0.1", "port": port}).ok, "actual UDP bind")
	a.truth(guest.connect_to({"host": "127.0.0.1", "port": port}).ok, "actual ENet connect")
	var tree: SceneTree = Engine.get_main_loop()
	var received := false
	for frame in 180:
		for e in host.poll_nonblocking():
			if e.type == "packet":
				a.equal(e.bytes.get_string_from_utf8(), "enet-test", "actual packet bytes")
				received = true
		for e in guest.poll_nonblocking():
			if e.type == "connect": guest.send(e.peer, 0, "enet-test".to_utf8_buffer(), true)
		if received: break
		await tree.process_frame
	a.truth(received, "loopback delivered")
	host.close()
	guest.close()
