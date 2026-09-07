class_name InputFrame
extends RefCounted

var seq: int = 0
var sample_tick: int = 0
var axes: Vector2 = Vector2.ZERO
var yaw: float = 0.0
var pitch: float = 0.0
var held_buttons: int = 0
var actions: Array = []

const FIRE = 1
const ADS = 2
const SPRINT = 4
const CROUCH = 8
const INTERACT = 16
const AIM = 32

func held(button: int) -> bool:
	return held_buttons & button != 0

func has_action(kind: String) -> bool:
	for a in actions:
		if a.kind == kind: return true
	return false

func neutral() -> InputFrame:
	var copy := InputFrame.new()
	copy.seq = seq
	copy.sample_tick = sample_tick
	copy.yaw = yaw
	copy.pitch = pitch
	return copy
