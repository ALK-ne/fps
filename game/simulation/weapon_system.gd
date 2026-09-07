class_name WeaponSystem
extends RefCounted

var config: GameConfig
var queries: ArenaQueries
var projectiles: Array = []
var next_id: int = 1
var round_seed: int = 1
var events: Array = []

func fire(player: PlayerState, frame: InputFrame, tick: int) -> void:
	var gun := player.inventory.active()
	if gun.is_empty() or player.movement.vaulting: return
	var definition := config.weapon(gun.kind)
	var pressed := frame.has_action("fire") or (frame.held(InputFrame.FIRE) and not player.last_fire)
	if not frame.held(InputFrame.FIRE) and not pressed: return
	if not definition.automatic and not pressed: return
	if player.action == CanonicalCodec.Action.RELOAD and gun.magazine > 0: player.action = CanonicalCodec.Action.IDLE
	if player.action != CanonicalCodec.Action.IDLE or gun.magazine < 1: return
	var now := tick * 1000000 / 60
	if now < int(gun.next_shot_us): return
	if projectiles.size() + int(definition.pellets) > 128: return
	var old_next: int = gun.next_shot_us
	gun.next_shot_us = old_next + int(definition.intervalUs) if now - old_next < 16667 else now + int(definition.intervalUs)
	gun.magazine -= 1
	player.inventory.revision += 1
	player.movement.sprinting = false
	var eye := player.eye()
	var forward := player.direction()
	var right := Basis(Vector3.UP, player.yaw) * Vector3.RIGHT
	var muzzle := eye + forward * 0.4 + right * 0.18 - Vector3.UP * 0.15
	var aim_hit := queries.first_bullet_hit(eye, eye + forward * float(definition.bulletSpeed) * 2.0, player.slot)
	var target: Vector3 = aim_hit.position if not aim_hit.is_empty() else eye + forward * float(definition.bulletSpeed) * 2.0
	var obstructed := not queries.ray(eye, muzzle).is_empty()
	var aim := (target - muzzle).normalized()
	var rng := RandomNumberGenerator.new()
	rng.seed = round_seed ^ next_id
	var shot_id := next_id
	var spread: float = definition.adsDegrees if frame.held(InputFrame.ADS) else definition.hipDegrees
	if not player.movement.grounded and not frame.held(InputFrame.ADS): spread *= 2
	for pellet in int(definition.pellets):
		var cosine := lerpf(cos(deg_to_rad(spread)), 1, rng.randf())
		var angle := rng.randf() * TAU
		var tangent := aim.cross(Vector3.UP).normalized()
		var up := tangent.cross(aim).normalized()
		var dir := (aim * cosine + (tangent * cos(angle) + up * sin(angle)) * sqrt(maxf(0, 1 - cosine * cosine))).normalized()
		if not obstructed:
			projectiles.append({"id": next_id, "owner": player.slot, "kind": int(gun.kind), "position": muzzle, "velocity": dir * float(definition.bulletSpeed), "expiry_tick": tick + 120, "shot_id": shot_id})
		next_id += 1
	player.recoil += Vector2(deg_to_rad(definition.recoilDegrees), deg_to_rad(definition.recoilDegrees * rng.randf_range(-0.2, 0.2))) * Vector2(-1, 1)
	events.append({"kind": "shot", "slot": player.slot, "weapon": gun.kind, "position": muzzle, "id": shot_id})

func step(tick: int) -> Array:
	var damage: Array = []
	for i in range(projectiles.size() - 1, -1, -1):
		var p: Dictionary = projectiles[i]
		var to: Vector3 = p.position + p.velocity / 60.0
		var hit := queries.first_bullet_hit(p.position, to, p.owner)
		if not hit.is_empty():
			var collider: Object = hit.collider
			if collider.has_meta("slot"):
				var definition := config.weapon(p.kind)
				var head: bool = collider.get_meta("head", false)
				damage.append({"kind": "damage", "target": int(collider.get_meta("slot")), "owner": p.owner, "amount": int(round(float(definition.damage) * 1000 * (float(definition.headMultiplier) if head else 1.0))), "head": head, "shot_id": p.shot_id})
			projectiles.remove_at(i)
		elif tick >= p.expiry_tick: projectiles.remove_at(i)
		else: p.position = to
	return damage

func reload_begin(player: PlayerState, tick: int) -> DuelResult:
	var gun := player.inventory.active()
	if gun.is_empty() or player.action != CanonicalCodec.Action.IDLE: return DuelResult.failure("ACTION_CONFLICT")
	var definition := config.weapon(gun.kind)
	if gun.magazine >= definition.magazine or player.inventory.reserve[int(gun.kind) - 1] <= 0: return DuelResult.failure("NO_STOCK")
	player.action = CanonicalCodec.Action.RELOAD
	player.action_end_tick = tick + config.ticks(definition.reloadMs)
	return DuelResult.success()

func complete(player: PlayerState, tick: int) -> void:
	if player.hp_milli <= 0:
		player.action = CanonicalCodec.Action.IDLE
		return
	if tick < player.action_end_tick: return
	if player.action == CanonicalCodec.Action.SWITCH:
		player.inventory.active_slot = player.action_kind
		player.inventory.revision += 1
		player.action = CanonicalCodec.Action.IDLE
	elif player.action == CanonicalCodec.Action.RELOAD:
		var gun := player.inventory.active()
		if not gun.is_empty():
			var sub: int = gun.kind - 1
			var amount := mini(int(config.weapon(gun.kind).magazine) - int(gun.magazine), player.inventory.reserve[sub])
			gun.magazine += amount
			player.inventory.reserve[sub] -= amount
			player.inventory.revision += 1
		player.action = CanonicalCodec.Action.IDLE
