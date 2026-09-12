extends RefCounted

func test_sequence_limits_and_conflicting_fragment(a: DuelAssertions) -> void:
	var sender := PacketCodec.new()
	var key := DuelIds.random_bytes(32)
	var mid := DuelIds.random_bytes(16)
	sender.outgoing[0] = 0x7fffffffffffffff
	a.truth(sender.encode(5, PackedByteArray([1]), mid, 1, 0, 0, key).is_empty(), "packet sequence cannot wrap")
	a.equal(sender.outgoing[0], 0x7fffffffffffffff, "exhausted sequence unchanged")
	sender.outgoing[0] -= 1
	var packet: PackedByteArray = sender.encode(5, PackedByteArray([1]), mid, 1, 0, 0, key)[0]
	a.truth(PacketCodec.new().decode(packet, key, mid, 0, 1).ok, "last signed-positive sequence accepted")
	var parts := sender.encode(24, DuelIds.random_bytes(2048), mid, 1, 0, 3, key)
	var receiver := PacketCodec.new()
	var fragment: PackedByteArray = parts[0].slice(48, parts[0].size() - 32)
	a.equal(receiver._assemble(24, fragment).error_code, "FRAGMENT_PENDING", "first fragment retained")
	fragment[16] ^= 1
	a.equal(receiver._assemble(24, fragment).error_code, "INVALID_FRAGMENT", "same fragment index with changed bytes rejected")
	a.equal(receiver.fragments.size(), 0, "conflicting assembly discarded")
	a.equal(MessagePolicy.decoded(12, {"round": 1, "tick": -1, "requiredEventSeq": 0, "entities": []}).error_code, "INTEGER_RANGE", "u64 high-bit values cannot reach live simulation")

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

func test_snapshot_rejects_invalid_state(a: DuelAssertions) -> void:
	var p := PlayerState.new()
	var q := PlayerState.new()
	q.slot = 1
	p.yaw = TAU * 20 + 0.5
	var data := {"round": 1, "tick": 123, "players": [Replication.player_data(p), Replication.player_data(q)]}
	var result := SnapshotCodec.decode(SnapshotCodec.encode(data))
	a.truth(result.ok, "many full turns remain valid after wire normalization")
	a.truth(absf(result.value.players[0].yaw - 0.5) < 0.00001, "normalized yaw preserves direction")
	var invalid: Dictionary = MessageCodec.decode(11, SnapshotCodec.encode(data)).value
	invalid.player0.inventory.reserveShotgun = 31
	a.equal(SnapshotCodec.decode(MessageCodec.encode(11, invalid).value).error_code, "INVENTORY_CAP", "live decoder rejects excessive shotgun reserve")
	invalid.player0.inventory.reserveShotgun = 0
	invalid.player0.vaultStart.x = NAN
	var bytes := SnapshotCodec.encode(data)
	# player0 vaultStart follows header12 + player prefix66.
	bytes.encode_u32(78, 0x7fc00000)
	a.equal(SnapshotCodec.decode(bytes).error_code, "NON_FINITE", "live decoder rejects nonfinite vault metadata")
	invalid = MessageCodec.decode(11, SnapshotCodec.encode(data)).value
	invalid.player0.armorMax = 125000
	a.equal(SnapshotCodec.decode(MessageCodec.encode(11, invalid).value).error_code, "INVALID_PLAYER", "armor tier must match round")

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

func test_snapshot_inventory_revision(a: DuelAssertions) -> void:
	var player := PlayerState.new()
	var old := Replication.player_data(player)
	player.inventory.revision = 2
	player.inventory.reserve[0] = 24
	old.position = Vector3(1, 0, 0)
	Replication.apply_player(player, old)
	a.equal(player.inventory.reserve[0], 24, "old inventory snapshot cannot roll back later pickup")
	a.equal(player.position, Vector3(1, 0, 0), "movement still updates independently")
	Replication.apply_player(player, old, true)
	a.equal(player.inventory.revision, 0, "explicit world baseline can replace old-round inventory")

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

func test_reordering_window(a: DuelAssertions) -> void:
	var sender := PacketCodec.new()
	var receiver := PacketCodec.new()
	var key := DuelIds.random_bytes(32)
	var mid := DuelIds.random_bytes(16)
	var packets: Array = []
	for i in 1026: packets.append(sender.encode(5, PackedByteArray(), mid, 1, 0, 0, key)[0])
	for i in [0, 2, 1]: a.truth(receiver.decode(packets[i], key, mid, 0, 1).ok, "unseen reordered sequence")
	a.truth(not receiver.decode(packets[1], key, mid, 0, 1).ok, "duplicate in window rejected")
	a.truth(receiver.decode(packets[1025], key, mid, 0, 1).ok, "window advances")
	a.truth(not receiver.decode(packets[0], key, mid, 0, 1).ok, "expired sequence rejected")
	a.truth(receiver.decode(packets[3], key, mid, 0, 1).ok, "old unseen sequence within 1024 accepted")

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
