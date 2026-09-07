class_name ENetTransport
extends RefCounted

var connection: ENetConnection
var server_peer: ENetPacketPeer

func listen(endpoint: Dictionary) -> DuelResult:
	close()
	connection = ENetConnection.new()
	var err := connection.create_host_bound(str(endpoint.get("bind", "*")), int(endpoint.port), 4, 4)
	return DuelResult.success() if err == OK else DuelResult.failure("PORT_IN_USE", str(err))

func connect_to(endpoint: Dictionary) -> DuelResult:
	close()
	connection = ENetConnection.new()
	var err := connection.create_host(1, 4)
	if err != OK: return DuelResult.failure("NETWORK_ERROR", str(err))
	server_peer = connection.connect_to_host(str(endpoint.host), int(endpoint.port), 4)
	if server_peer == null: return DuelResult.failure("NETWORK_ERROR")
	return DuelResult.success()

func poll_nonblocking(max_events: int = 64) -> Array:
	var events: Array = []
	if connection == null: return events
	var start := Time.get_ticks_usec()
	for i in max_events:
		var event := connection.service(0)
		if event[0] == ENetConnection.EVENT_NONE: break
		if event[0] == ENetConnection.EVENT_ERROR:
			events.append({"type": "error"})
			break
		var peer: ENetPacketPeer = event[1]
		match int(event[0]):
			ENetConnection.EVENT_CONNECT: events.append({"type": "connect", "peer": peer})
			ENetConnection.EVENT_DISCONNECT: events.append({"type": "disconnect", "peer": peer})
			ENetConnection.EVENT_RECEIVE: events.append({"type": "packet", "peer": peer, "channel": int(event[3]), "bytes": peer.get_packet()})
		if Time.get_ticks_usec() - start >= 2000: break
	return events

func send(peer: ENetPacketPeer, channel: int, bytes: PackedByteArray, reliable: bool) -> DuelResult:
	if connection == null or peer == null: return DuelResult.failure("NOT_CONNECTED")
	var err := peer.send(channel, bytes, ENetPacketPeer.FLAG_RELIABLE if reliable else 0)
	connection.flush()
	return DuelResult.success() if err == OK else DuelResult.failure("SEND_FAILED")

func close() -> void:
	if connection != null: connection.destroy()
	connection = null
	server_peer = null
