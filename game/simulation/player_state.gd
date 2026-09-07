class_name PlayerState
extends RefCounted

var slot: int = 0
var movement := MovementState.new()
var yaw: float = 0.0
var pitch: float = 0.0
var hp_milli: int = 100000
var armor_milli: int = 50000
var armor_max: int = 50000
var inventory := Inventory.new()
var action: int = CanonicalCodec.Action.IDLE
var action_end_tick: int = 0
var action_kind: int = 0
var action_target: int = 0
var action_revision: int = 0
var last_input_seq: int = 0
var recoil: Vector2 = Vector2.ZERO
var next_melee_tick: int = 0
var last_fire: bool = false
var alive_at_start: bool = true

var position: Vector3:
	get: return movement.position
	set(value): movement.position = value
var velocity: Vector3:
	get: return movement.velocity
	set(value): movement.velocity = value

func eye() -> Vector3:
	return position + Vector3.UP * (1.0 if movement.crouched else 1.62)

func direction() -> Vector3:
	return Basis.from_euler(Vector3(pitch + recoil.x, yaw + recoil.y, 0)) * Vector3.FORWARD

func reset(round_number: int) -> void:
	hp_milli = 100000
	armor_max = MatchReducer.armor_for_round(round_number) * 1000
	armor_milli = armor_max
	inventory = Inventory.new()
	action = CanonicalCodec.Action.IDLE
	action_end_tick = 0
	action_kind = 0
	action_target = 0
	action_revision = 0
	yaw = 0.0
	pitch = 0.0
	alive_at_start = true
	recoil = Vector2.ZERO
	last_fire = false
	next_melee_tick = 0
	movement = MovementState.new()
