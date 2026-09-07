class_name SnapshotCodec
extends RefCounted

static func encode(d: Dictionary) -> PackedByteArray:
	var s := StreamPeerBuffer.new()
	s.put_u32(d.round)
	s.put_u64(d.tick)
	for p in d.players:
		s.put_u8(p.slot)
		_vector(s, p.position)
		_vector(s, p.velocity)
		s.put_float(p.yaw)
		s.put_float(p.pitch)
		s.put_32(p.hp)
		s.put_32(p.armor)
		s.put_32(p.armor_max)
		s.put_u8((1 if p.grounded else 0) | (2 if p.crouched else 0) | (4 if p.sprinting else 0) | (8 if p.vaulting else 0))
		s.put_u8(p.action)
		s.put_u64(p.action_end)
		s.put_u8(p.action_kind)
		s.put_u64(p.ack)
		s.put_u16(p.slide)
		_vector(s, p.vault_start)
		_vector(s, p.vault_end)
		s.put_u16(p.vault_progress)
		s.put_float(p.recoil[0])
		s.put_float(p.recoil[1])
		var inv: Dictionary = p.inventory
		s.put_u32(inv.revision)
		s.put_8(inv.active_slot)
		for gun in inv.weapons:
			s.put_u32(0 if gun == null else gun.id)
			s.put_u8(0 if gun == null else gun.kind)
			s.put_u16(0 if gun == null else gun.magazine)
		for n in inv.reserve: s.put_u16(n)
		for n in inv.heals: s.put_u8(n)
		for n in inv.grenades: s.put_u8(n)
		s.put_u8(inv.selected_heal)
		s.put_u8(inv.selected_grenade)
	return s.data_array

static func decode(bytes: PackedByteArray) -> DuelResult:
	# Fixed size: 12-byte snapshot header and 133 bytes per player.
	if bytes.size() != 278: return DuelResult.failure("INVALID_SNAPSHOT_SIZE", str(bytes.size()))
	var s := StreamPeerBuffer.new()
	s.data_array = bytes
	var data := {"round": s.get_u32(), "tick": s.get_u64(), "players": []}
	for slot in 2:
		var p := {"slot": s.get_u8(), "position": _read_vector(s), "velocity": _read_vector(s), "yaw": s.get_float(), "pitch": s.get_float(),
			"hp": s.get_32(), "armor": s.get_32(), "armor_max": s.get_32()}
		var flags := s.get_u8()
		p.grounded = flags & 1 != 0
		p.crouched = flags & 2 != 0
		p.sprinting = flags & 4 != 0
		p.vaulting = flags & 8 != 0
		p.action = s.get_u8()
		p.action_end = s.get_u64()
		p.action_kind = s.get_u8()
		p.ack = s.get_u64()
		p.slide = s.get_u16()
		p.vault_start = _read_vector(s)
		p.vault_end = _read_vector(s)
		p.vault_progress = s.get_u16()
		p.recoil = [s.get_float(), s.get_float()]
		var inv := Inventory.new().to_data()
		inv.revision = s.get_u32()
		inv.active_slot = s.get_8()
		for i in 2:
			var id := s.get_u32()
			var kind := s.get_u8()
			var magazine := s.get_u16()
			if kind > 3 or magazine > 24: return DuelResult.failure("INVALID_INVENTORY")
			inv.weapons[i] = null if kind == 0 else {"id": id, "kind": kind, "magazine": magazine, "next_shot_us": 0}
		for i in 3: inv.reserve[i] = s.get_u16()
		for i in 4: inv.heals[i] = s.get_u8()
		for i in 2: inv.grenades[i] = s.get_u8()
		inv.selected_heal = s.get_u8()
		inv.selected_grenade = s.get_u8()
		p.inventory = inv
		if p.slot != slot or flags > 15 or p.action > 7 or inv.active_slot < -1 or inv.active_slot > 1 or p.hp < 0 or p.hp > 100000 or p.armor < 0 or p.armor > 125000: return DuelResult.failure("INVALID_PLAYER")
		if not p.position.is_finite() or not p.velocity.is_finite() or not is_finite(p.yaw) or not is_finite(p.pitch): return DuelResult.failure("NONFINITE")
		data.players.append(p)
	return DuelResult.success(data)

static func _vector(s: StreamPeerBuffer, v: Vector3) -> void:
	s.put_float(v.x)
	s.put_float(v.y)
	s.put_float(v.z)

static func _read_vector(s: StreamPeerBuffer) -> Vector3:
	return Vector3(s.get_float(), s.get_float(), s.get_float())
