class_name Prediction
extends RefCounted

var frames: Array[InputFrame] = []
var overflow: bool = false
var corrections: Array[float] = []
var camera_offset := Vector3.ZERO
var offset_remaining: float = 0.0
var needs_baseline: bool = false

func reset() -> void:
	frames.clear()
	overflow = false
	needs_baseline = false
	camera_offset = Vector3.ZERO
	offset_remaining = 0.0

func advance_camera(delta: float) -> Vector3:
	if offset_remaining <= 0: return Vector3.ZERO
	var next := maxf(0, offset_remaining - delta)
	camera_offset *= next / offset_remaining
	offset_remaining = next
	return camera_offset

func predict(player: PlayerState, input: InputFrame, solver: MovementSolver) -> void:
	frames.append(input)
	if frames.size() > 256:
		frames.clear()
		overflow = true
		needs_baseline = true
	player.movement = solver.step(player, input)

func reconcile(player: PlayerState, authoritative: Dictionary, solver: MovementSolver) -> void:
	var old := player.position
	var old_eye := player.eye() + camera_offset
	Replication.apply_player(player, authoritative)
	while not frames.is_empty() and frames[0].seq <= player.last_input_seq: frames.pop_front()
	if overflow:
		frames.clear()
		overflow = false
	else:
		for frame in frames: player.movement = solver.step(player, frame)
	corrections.append(old.distance_to(player.position))
	if corrections.size() > 10000: corrections.pop_front()
	var offset := old_eye - player.eye()
	var blocked := not solver.queries.ray(player.eye(), old_eye).is_empty()
	if offset.length() >= 1.0 or blocked or needs_baseline:
		camera_offset = Vector3.ZERO
		offset_remaining = 0
		needs_baseline = true
	else:
		camera_offset = offset
		offset_remaining = 0.1
