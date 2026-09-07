class_name MovementState
extends RefCounted

var position: Vector3 = Vector3.ZERO
var velocity: Vector3 = Vector3.ZERO
var grounded: bool = false
var crouched: bool = false
var sprinting: bool = false
var slide_remaining_ticks: int = 0
var vault_start: Vector3
var vault_end: Vector3
var vault_progress_ticks: int = 0
var vaulting: bool = false
var last_crouch: bool = false

func clone() -> MovementState:
	var copy := MovementState.new()
	for key in ["position", "velocity", "grounded", "crouched", "sprinting", "slide_remaining_ticks", "vault_start", "vault_end", "vault_progress_ticks", "vaulting", "last_crouch"]:
		copy.set(key, get(key))
	return copy
