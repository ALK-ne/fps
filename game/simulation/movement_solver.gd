class_name MovementSolver
extends RefCounted

var queries: ArenaQueries
var config: GameConfig

func step(player: PlayerState, frame: InputFrame, dt: float = 1.0 / 60.0) -> MovementState:
	var state := player.movement.clone()
	var m: Dictionary = config.rules.movement
	if state.vaulting:
		state.vault_progress_ticks += 1
		var t := clampf(state.vault_progress_ticks / 18.0, 0, 1)
		var target := state.vault_start.lerp(state.vault_end, smoothstep(0.0, 1.0, t)) + Vector3.UP * 0.15 * sin(PI * t)
		var moved := queries.move_body(player.slot, state, target - state.position, true)
		if moved.position.distance_to(target) > 0.08 or t >= 1: moved.vaulting = false
		return moved
	var crouch := frame.held(InputFrame.CROUCH)
	var healing := player.action == CanonicalCodec.Action.HEAL
	state.sprinting = frame.held(InputFrame.SPRINT) and not frame.held(InputFrame.FIRE) and not frame.held(InputFrame.ADS) and not healing and frame.axes.length() > 0
	if crouch and not state.last_crouch and state.grounded and state.sprinting and not healing:
		state.slide_remaining_ticks = 42
		var forward := Vector3(-sin(frame.yaw), 0, -cos(frame.yaw))
		state.velocity = (Vector3(state.velocity.x, 0, state.velocity.z).normalized() if state.velocity.length() > 0.1 else forward) * float(m.slideSpeed)
	state.last_crouch = crouch
	state.crouched = crouch or (state.crouched and not queries.standing_clear(player.slot, state.position))
	if state.crouched: state.sprinting = false
	if not crouch or Vector2(state.velocity.x, state.velocity.z).length() < 3: state.slide_remaining_ticks = 0
	if frame.has_action("jump") and state.grounded:
		var vault := queries.vault_destination(player.slot, player)
		if vault.ok and not healing:
			state.vaulting = true
			state.vault_start = state.position
			state.vault_end = vault.value
			state.vault_progress_ticks = 0
			return state
		state.velocity.y = m.jumpSpeed
		state.grounded = false
		state.slide_remaining_ticks = 0
	var axis := frame.axes.limit_length()
	var direction := Basis(Vector3.UP, frame.yaw) * Vector3(axis.x, 0, axis.y)
	var horizontal := Vector3(state.velocity.x, 0, state.velocity.z)
	if state.slide_remaining_ticks > 0:
		state.slide_remaining_ticks -= 1
		horizontal = horizontal.move_toward(Vector3.ZERO, float(m.slideBrake) * dt)
	else:
		var speed: float = m.sprint if state.sprinting else (m.crouch if state.crouched else m.walk)
		if frame.held(InputFrame.ADS): speed *= config.rules.combat.adsMoveMultiplier
		if state.grounded:
			horizontal = horizontal.move_toward(direction * speed, float(m.groundAccel if axis.length() > 0 else m.brake) * dt)
		else:
			var cap := maxf(horizontal.length(), float(m.sprint))
			horizontal = (horizontal + direction * float(m.airAccel) * dt).limit_length(cap)
	state.velocity.x = horizontal.x
	state.velocity.z = horizontal.z
	state.velocity.y -= float(m.gravity) * dt
	return queries.move_body(player.slot, state, state.velocity * dt)
