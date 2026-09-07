class_name Prediction
extends RefCounted

var frames: Array[InputFrame] = []
var overflow: bool = false
var corrections: Array[float] = []

func predict(player: PlayerState, input: InputFrame, solver: MovementSolver) -> void:
	frames.append(input)
	if frames.size() > 256:
		frames.clear()
		overflow = true
	player.movement = solver.step(player, input)

func reconcile(player: PlayerState, authoritative: Dictionary, solver: MovementSolver) -> void:
	var old := player.position
	Replication.apply_player(player, authoritative)
	while not frames.is_empty() and frames[0].seq <= player.last_input_seq: frames.pop_front()
	if overflow:
		frames.clear()
		overflow = false
	else:
		for frame in frames: player.movement = solver.step(player, frame)
	corrections.append(old.distance_to(player.position))
	if corrections.size() > 10000: corrections.pop_front()
