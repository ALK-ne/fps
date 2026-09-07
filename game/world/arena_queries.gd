class_name ArenaQueries
extends RefCounted

var arena: ArenaBuilder
var proxies: Array = []

func ray(from: Vector3, to: Vector3, mask: int = 1, exclude: Array[RID] = []) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to, mask, exclude)
	query.collide_with_areas = true
	return arena.get_world_3d().direct_space_state.intersect_ray(query)

func move_body(slot: int, state: MovementState, delta: Vector3, collide_players: bool = false) -> MovementState:
	var result := state.clone()
	var body: CharacterBody3D = proxies[slot]
	var previous_mask := body.collision_mask
	if collide_players: body.collision_mask = 3
	body.set_crouched(state.crouched)
	var remaining := delta
	result.grounded = false
	for iteration in 4:
		if remaining.length_squared() < 0.00000001: break
		var params := PhysicsTestMotionParameters3D.new()
		params.from = Transform3D(Basis.IDENTITY, result.position)
		params.motion = remaining
		params.margin = 0.001
		params.recovery_as_collision = true
		var hit := PhysicsTestMotionResult3D.new()
		if not PhysicsServer3D.body_test_motion(body.get_rid(), params, hit):
			result.position += remaining
			break
		result.position += hit.get_travel()
		var normal := hit.get_collision_normal()
		if normal.dot(Vector3.UP) >= cos(deg_to_rad(45)):
			result.grounded = true
		remaining = hit.get_remainder().slide(normal)
		result.velocity = result.velocity.slide(normal)
	if result.velocity.y <= 0 and not state.vaulting:
		var params := PhysicsTestMotionParameters3D.new()
		params.from = Transform3D(Basis.IDENTITY, result.position)
		params.motion = Vector3.DOWN * 0.15
		params.margin = 0.001
		var hit := PhysicsTestMotionResult3D.new()
		if PhysicsServer3D.body_test_motion(body.get_rid(), params, hit) and hit.get_collision_normal().y >= 0.707:
			result.position += hit.get_travel()
			result.grounded = true
			result.velocity.y = 0
	body.collision_mask = previous_mask
	return result

func standing_clear(slot: int, position: Vector3) -> bool:
	var shape := CapsuleShape3D.new()
	shape.radius = 0.35
	shape.height = 1.8
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.transform.origin = position + Vector3.UP * 0.91
	q.collision_mask = 3
	q.exclude = [proxies[slot].get_rid()]
	return arena.get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty()

func vault_destination(slot: int, player: PlayerState) -> DuelResult:
	var forward := Vector3(-sin(player.yaw), 0, -cos(player.yaw))
	var low := ray(player.position + Vector3.UP * 0.45, player.position + Vector3.UP * 0.45 + forward)
	if low.is_empty(): return DuelResult.failure("NO_VAULT")
	var depth_limit: float = arena.config.rules.movement.vaultMaxDepth
	var back := ray(low.position + forward * (depth_limit + 0.01), low.position - forward * 0.01)
	if back.is_empty() or back.collider != low.collider or (back.position - low.position).dot(forward) > depth_limit: return DuelResult.failure("NO_VAULT")
	var top := ray(low.position + forward * 0.1 + Vector3.UP * 1.3, low.position + forward * 0.1)
	if top.is_empty(): return DuelResult.failure("NO_VAULT")
	var height: float = top.position.y - player.position.y
	if height < 0.5 or height > 1.2: return DuelResult.failure("NO_VAULT")
	var end: Vector3 = top.position + forward * 0.05 + Vector3.UP * 0.02
	if not standing_clear(slot, end): return DuelResult.failure("NO_VAULT")
	var probe := player.movement.clone()
	probe.vaulting = true
	for step in range(1, 19):
		var t := step / 18.0
		var target := player.position.lerp(end, smoothstep(0.0, 1.0, t)) + Vector3.UP * 0.15 * sin(PI * t)
		probe = move_body(slot, probe, target - probe.position, true)
		if probe.position.distance_to(target) > 0.08: return DuelResult.failure("NO_VAULT")
	return DuelResult.success(end)

func first_bullet_hit(from: Vector3, to: Vector3, exclude_slot: int) -> Dictionary:
	var exclude: Array[RID] = []
	if exclude_slot >= 0 and exclude_slot < proxies.size():
		exclude = proxies[exclude_slot].hitbox_rids()
	return ray(from, to, 5, exclude)

func pickup_target(player: PlayerState, distance: float = 2.0) -> Dictionary:
	return ray(player.eye(), player.eye() + player.direction() * distance, 9)

func grenade_sweep(from: Vector3, to: Vector3, radius: float = 0.1) -> Dictionary:
	var shape := SphereShape3D.new()
	shape.radius = radius
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.transform.origin = from
	q.motion = to - from
	q.collision_mask = 3
	var space := arena.get_world_3d().direct_space_state
	var fraction := space.cast_motion(q)
	if fraction[0] >= 1.0: return {}
	q.transform.origin = from + q.motion * fraction[1]
	q.motion = Vector3.ZERO
	q.margin = 0.005
	var rest := space.get_rest_info(q)
	if rest.is_empty():
		return {"position": from + (to - from) * fraction[0], "normal": (from - to).normalized(), "fraction": fraction[0]}
	return {"position": from + (to - from) * fraction[0], "normal": rest.normal, "fraction": fraction[0]}

func explosion_visible(origin: Vector3, player: PlayerState) -> bool:
	return ray(origin, player.position + Vector3.UP * 0.8).is_empty() or ray(origin, player.eye()).is_empty()
