extends RefCounted

func test_transport_gate(a: DuelAssertions) -> void:
	a.equal(MessagePolicy.TABLE.size(), 32, "policy covers every message")
	for kind in MessagePolicy.TABLE:
		var rule: Array = MessagePolicy.TABLE[kind]
		var sender: int = maxi(0, rule[1])
		var auth: bool = kind > 4
		var phase: int = rule[2][0] if auth else 0
		a.truth(MessagePolicy.envelope(kind, rule[0], sender, auth, phase, kind).ok, "legal gate type %d" % kind)
		a.truth(not MessagePolicy.envelope(kind, (rule[0] + 1) % 4, sender, auth, phase, kind).ok, "wrong channel rejected")
		if rule[1] >= 0: a.equal(MessagePolicy.envelope(kind, rule[0], 1 - sender, auth, phase, kind).error_code, "WRONG_DIRECTION", "bound sender controls direction")
		if auth: a.equal(MessagePolicy.envelope(kind, rule[0], sender, false, phase).error_code, "NOT_AUTHENTICATED", "session message before authentication rejected")
		else: a.equal(MessagePolicy.envelope(kind, rule[0], sender, false, phase, 99).error_code, "WRONG_AUTH_STAGE", "wrong handshake step rejected")
	a.equal(MessagePolicy.envelope(10, 1, 1, true, 7).error_code, "WRONG_PHASE", "suspended input is a gameplay refusal")
	a.truth(MessagePolicy.envelope(44, 0, 0, true, 10).ok, "storage error still permits diagnostics")
	a.truth(not MessagePolicy.envelope(30, 3, 0, true, 10).ok, "storage error cannot accept new durable gameplay")
	a.truth(MessagePolicy.envelope(41, 0, 1, true, 10).ok, "storage error permits leave")

func test_input_and_inventory_semantics(a: DuelAssertions) -> void:
	var sample := {"seq": 1, "sampleTick": 1, "axisX": 0, "axisY": 0, "yaw": 0.0, "pitch": 0.0, "held": 0}
	var data := {"round": 1, "samples": [sample]}
	a.truth(MessagePolicy.decoded(10, data).ok, "valid input")
	sample.axisX = -32768
	a.equal(MessagePolicy.decoded(10, data).error_code, "INVALID_INPUT", "reserved signed axis endpoint")
	sample.axisX = 0
	sample.held = 64
	a.truth(not MessagePolicy.decoded(10, data).ok, "unknown hold bit")
	sample.held = 0
	sample.yaw = 4.0
	a.equal(MessagePolicy.decoded(10, data).error_code, "ANGLE_RANGE", "yaw bounds")
	sample.yaw = 0.0
	data.samples.append(sample.duplicate())
	a.truth(not MessagePolicy.decoded(10, data).ok, "bundle sequence strictly increasing")
	var action := {"round": 1, "actionId": 1, "inputSeq": 1, "sampleTick": 1, "actionType": 1, "targetId": 0, "expectedRevision": 0, "argument": 0}
	a.truth(MessagePolicy.decoded(20, action).ok, "legal weapon switch")
	action.targetId = 1
	a.truth(not MessagePolicy.decoded(20, action).ok, "target only belongs to interact")
	action.targetId = 0
	action.argument = 2
	a.truth(not MessagePolicy.decoded(20, action).ok, "switch argument range")
	var inv := {"revision": 0, "activeSlot": -1, "weapon0": {"id": 0, "kind": 0, "magazine": 0}, "weapon1": {"id": 0, "kind": 0, "magazine": 0}, "reserveRifle": 120, "reserveShotgun": 30, "reservePistol": 60, "healthSmall": 4, "healthFull": 2, "armorSmall": 4, "armorFull": 2, "frag": 1, "incendiary": 1, "selectedHeal": 1, "selectedGrenade": 1}
	a.truth(MessagePolicy.decoded(22, {"round": 1, "firstEventSeq": 1, "serverTick": 0, "events": [EntityWire.tagged(4, {"slot": 0, "inventory": inv})]}).ok, "all inventory caps legal")
	inv.reserveRifle = 121
	a.equal(MessagePolicy.decoded(22, {"round": 1, "firstEventSeq": 1, "serverTick": 0, "events": [EntityWire.tagged(4, {"slot": 0, "inventory": inv})]}).error_code, "INVENTORY_CAP", "reserve above cap rejected")
	inv.reserveRifle = 120
	inv.weapon0 = {"id": 1, "kind": 1, "magazine": 24}
	inv.weapon1 = inv.weapon0.duplicate()
	a.equal(MessagePolicy.decoded(22, {"round": 1, "firstEventSeq": 1, "serverTick": 0, "events": [EntityWire.tagged(4, {"slot": 0, "inventory": inv})]}).error_code, "DUPLICATE_WEAPON", "duplicate weapon IDs rejected")
	a.equal(MessagePolicy.decoded(12, {"velocity": {"x": 1025.0, "y": 0.0, "z": 0.0}}).error_code, "VECTOR_RANGE", "velocity has stricter bound")

func test_ingress_validation_order(a: DuelAssertions) -> void:
	var sample := {"seq": 1, "sampleTick": 1, "axisX": 0, "axisY": 0, "yaw": 0.0, "pitch": 0.0, "held": 0}
	var bytes: PackedByteArray = MessageCodec.encode(10, {"round": 1, "samples": [sample]}).value
	a.truth(MessagePolicy.receive(10, bytes, 1, 1, true, 5).ok, "legal typed input passes ingress")
	a.equal(MessagePolicy.receive(10, PackedByteArray(), 1, 1, false, 5).error_code, "NOT_AUTHENTICATED", "authentication checked before payload parsing")
	a.equal(MessagePolicy.receive(10, PackedByteArray(), 1, 1, true, 5).error_code, "TRUNCATED", "authenticated payload still needs exact structure")
	bytes.encode_u16(bytes.size() - 2, 64)
	a.equal(MessagePolicy.receive(10, bytes, 1, 1, true, 5).error_code, "INVALID_INPUT", "valid binary with illegal hold bit is refused")
