class_name RemoteInterpolation
extends RefCounted

const DELAY_TICKS := 6.0
const MAX_EXTRAPOLATION_TICKS := 6.0
var samples: Array[Dictionary] = []
var received_ms: int = 0

func clear() -> void:
	samples.clear()
	received_ms = 0

func push(tick: int, position: Vector3, velocity: Vector3, yaw: float, now_ms: int) -> void:
	if not samples.is_empty() and tick <= int(samples.back().tick): return
	samples.append({"tick": tick, "position": position, "velocity": velocity, "yaw": yaw})
	if samples.size() > 32: samples.pop_front()
	received_ms = now_ms

func sample(now_ms: int) -> Dictionary:
	if samples.is_empty(): return {}
	var latest: Dictionary = samples.back()
	var render_tick := float(latest.tick) + maxf(0, now_ms - received_ms) * 0.06 - DELAY_TICKS
	if render_tick <= float(samples[0].tick): return samples[0]
	for i in range(1, samples.size()):
		var next: Dictionary = samples[i]
		if render_tick > float(next.tick): continue
		var previous: Dictionary = samples[i - 1]
		var weight := (render_tick - float(previous.tick)) / float(next.tick - previous.tick)
		return {"position": (previous.position as Vector3).lerp(next.position, weight), "yaw": lerp_angle(previous.yaw, next.yaw, weight)}
	# A missing snapshot may advance the avatar for at most 100 ms; then freeze.
	var elapsed := minf(MAX_EXTRAPOLATION_TICKS, render_tick - float(latest.tick)) / 60.0
	return {"position": latest.position + latest.velocity * elapsed, "yaw": latest.yaw}
