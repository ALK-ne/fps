class_name InstanceLock
extends RefCounted

var server := TCPServer.new()

func acquire(port: int) -> DuelResult:
	if port < 1024 or port > 65535: return DuelResult.failure("INVALID_PORT")
	var err := server.listen(port, "127.0.0.1")
	return DuelResult.success() if err == OK else DuelResult.failure("PORT_IN_USE", "同じプロファイルが使用中です")

func release() -> void:
	server.stop()
