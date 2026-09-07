extends SceneTree

func _initialize() -> void:
	var key := PackedByteArray()
	key.resize(32)
	var body := PackedByteArray()
	body.resize(1200)
	var output: Dictionary = {}
	for reuse in [false, true]:
		var shared := Crypto.new()
		var started := Time.get_ticks_usec()
		for i in 200:
			var backend := shared if reuse else Crypto.new()
			var signature := backend.hmac_digest(HashingContext.HASH_SHA256, key, body)
			if signature.size() != 32:
				quit(1)
				return
		output["reuse" if reuse else "construct_each"] = (Time.get_ticks_usec() - started) / 1000.0
	print(JSON.stringify({"benchmark": "200 HMAC SHA256 1200-byte packets", "ms": output}))
	quit(0)
