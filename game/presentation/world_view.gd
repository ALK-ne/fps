class_name WorldView
extends Node3D

var config: GameConfig
var simulation: DuelSimulation
var arena: ArenaBuilder
var camera: Camera3D
var gun_mesh: Node3D
var items: Dictionary = {}
var projectile_meshes: Dictionary = {}
var grenade_meshes: Dictionary = {}
var flame_meshes: Dictionary = {}
var trajectory_mesh: MeshInstance3D
var bank := AudioBank.new()
var voices: Array[Node] = []
var last_positions: Array = [Vector3.ZERO, Vector3.ZERO]
var step_distances: Array = [0.0, 0.0]
var hit_until: int = 0
var head_hit: bool = false
var local_slot: int = 0
var frame_times: Array = []
var remote_interpolation := RemoteInterpolation.new()

func build(cfg: GameConfig) -> void:
	config = cfg
	arena = ArenaBuilder.new()
	add_child(arena)
	arena.build(cfg)
	var queries := ArenaQueries.new()
	queries.arena = arena
	for slot in 2:
		var body := PlayerBody.new()
		add_child(body)
		body.build(slot, arena.material(Color("ffb45b")))
		queries.proxies.append(body)
	simulation = DuelSimulation.new()
	simulation.setup(cfg, queries)
	camera = Camera3D.new()
	camera.near = 0.05
	camera.far = 100
	camera.current = true
	add_child(camera)
	gun_mesh = Node3D.new()
	camera.add_child(gun_mesh)
	trajectory_mesh = MeshInstance3D.new()
	trajectory_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(trajectory_mesh)
	bank.build()

func sync_items() -> void:
	var active: Dictionary = {}
	for item in simulation.pickup.items:
		if item.amount <= 0: continue
		var id: int = item.id
		active[id] = true
		if not items.has(id):
			var area := Area3D.new()
			area.collision_layer = 8
			area.collision_mask = 0
			area.set_meta("item_id", id)
			var shape := CollisionShape3D.new()
			shape.shape = SphereShape3D.new()
			shape.shape.radius = 0.3 if item.kind == 1 else 0.2
			area.add_child(shape)
			var color := Color("41d9ff") if item.kind == 1 else (Color("63e6a6") if item.kind == 3 else Color("ffb45b"))
			if item.kind == 1: _gun(area, item.subtype, color)
			else: _mesh(area, SphereMesh.new() if item.kind == 4 else BoxMesh.new(), Vector3.ZERO, Vector3.ONE * 0.3, color)
			add_child(area)
			items[id] = area
		items[id].position = item.position
	for id in items.keys():
		if not active.has(id):
			items[id].collision_layer = 0
			items[id].queue_free()
			items.erase(id)

func present(settings: SettingsStore, frame: InputFrame, delta: float) -> void:
	frame_times.append(delta * 1000)
	if frame_times.size() > 36000: frame_times.pop_front()
	for slot in 2:
		var player: PlayerState = simulation.players[slot]
		simulation.queries.proxies[slot].present(player, slot == local_slot)
		if local_slot == 1 and slot == 0:
			var displayed := remote_interpolation.sample(Time.get_ticks_msec())
			if not displayed.is_empty():
				# Keep authoritative physics at its current position; delay only the avatar.
				simulation.queries.proxies[slot].avatar.position = displayed.position - player.position
				simulation.queries.proxies[slot].avatar.rotation.y = displayed.yaw
		var distance: float = player.position.distance_to(last_positions[slot])
		last_positions[slot] = player.position
		if player.movement.grounded and distance < 1:
			step_distances[slot] += distance
			var stride := 2.4 if player.movement.crouched else (2.2 if player.movement.sprinting else 1.8)
			if step_distances[slot] >= stride:
				step_distances[slot] = 0
				play("step", player.position, 20, -8 if player.movement.crouched else 0)
	var local: PlayerState = simulation.players[local_slot]
	camera.position = local.eye()
	camera.rotation = Vector3(frame.pitch + local.recoil.x, frame.yaw + local.recoil.y, 0)
	camera.fov = lerpf(camera.fov, float(settings.values.verticalFov) * (0.8 if frame.held(InputFrame.ADS) else 1.0), minf(1, delta / 0.12))
	var gun := local.inventory.active()
	var kind: int = gun.get("kind", 0)
	if int(gun_mesh.get_meta("kind", -1)) != kind:
		for child in gun_mesh.get_children(): child.queue_free()
		gun_mesh.set_meta("kind", kind)
		if kind > 0: _gun(gun_mesh, kind, Color("41d9ff"))
	gun_mesh.position = Vector3(0.22, -0.24, -0.5) if not frame.held(InputFrame.ADS) else Vector3(0, -0.18, -0.48)
	gun_mesh.visible = kind > 0 and local.action not in [CanonicalCodec.Action.HEAL, CanonicalCodec.Action.GRENADE_READY, CanonicalCodec.Action.GRENADE_AIM]
	if not simulation.queries.ray(local.eye(), local.eye() + local.direction() * 0.7).is_empty(): gun_mesh.position.y -= 0.15
	sync_items()
	_sync_entities(simulation.weapons.projectiles, projectile_meshes, Color("fff0af"), Vector3(0.025, 0.025, 0.18))
	_sync_entities(simulation.grenade.grenades, grenade_meshes, Color("ffb45b"), Vector3.ONE * 0.2)
	var flame_data: Array = []
	for flame in simulation.grenade.flames:
		for i in flame.cells.size(): flame_data.append({"id": int(flame.id) * 100 + i, "position": flame.cells[i] + Vector3.UP * 0.15})
	_sync_entities(flame_data, flame_meshes, Color("ff714b"), Vector3(0.4, 0.3, 0.4))
	trajectory_mesh.visible = local.action == CanonicalCodec.Action.GRENADE_AIM
	if trajectory_mesh.visible:
		var mesh := ImmediateMesh.new()
		mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, arena.material(Color("f4f7fb")))
		for point in simulation.grenade.trajectory(local): mesh.surface_add_vertex(point)
		mesh.surface_end()
		trajectory_mesh.mesh = mesh

func _sync_entities(data: Array, meshes: Dictionary, color: Color, size: Vector3) -> void:
	var active: Dictionary = {}
	for entity in data:
		var id: int = entity.id
		active[id] = true
		if not meshes.has(id): meshes[id] = _mesh(self, BoxMesh.new(), entity.position, size, color)
		meshes[id].position = entity.position
	for id in meshes.keys():
		if not active.has(id):
			meshes[id].queue_free()
			meshes.erase(id)

func _mesh(parent: Node3D, mesh: Mesh, pos: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position = pos
	instance.scale = size
	instance.material_override = arena.material(color)
	parent.add_child(instance)
	return instance

func _gun(parent: Node3D, kind: int, color: Color) -> void:
	var length := 0.55 if kind == 1 else (0.65 if kind == 2 else 0.3)
	_mesh(parent, BoxMesh.new(), Vector3.ZERO, Vector3(0.13, 0.14, length), color)
	_mesh(parent, BoxMesh.new(), Vector3(0, -0.12, 0.08), Vector3(0.1, 0.2, 0.1), Color("26344d"))
	_mesh(parent, BoxMesh.new(), Vector3(0, 0, -length * 0.55), Vector3(0.065, 0.065, 0.14), Color("f4f7fb"))
	if kind == 1: _mesh(parent, BoxMesh.new(), Vector3(0, 0.1, -0.08), Vector3(0.055, 0.07, 0.15), Color("f4f7fb"))

func show_events(events: Array) -> void:
	for e in events:
		match str(e.kind):
			"shot": play(["rifle", "shotgun", "pistol"][int(e.weapon) - 1], e.position, 40)
			"pickup", "heal":
				if e.slot == local_slot: play("pickup", camera.position, 10)
			"damage":
				if e.get("owner", -1) == local_slot:
					hit_until = Time.get_ticks_msec() + 80
					head_hit = e.get("head", false)
					play("hit", camera.position, 10)
			"armor_break": play("armor", simulation.players[int(e.target)].eye(), 30)
			"explosion": play("explosion", e.position, 40)

func play(kind: String, pos: Vector3, distance: float, volume: float = 0) -> void:
	for i in range(voices.size() - 1, -1, -1):
		if not is_instance_valid(voices[i]): voices.remove_at(i)
	if voices.size() >= 32: return
	var voice := AudioStreamPlayer3D.new()
	voice.stream = bank.sounds[kind]
	voice.position = pos
	voice.max_distance = distance
	voice.unit_size = 3
	voice.volume_db = volume
	add_child(voice)
	voices.append(voice)
	voice.finished.connect(voice.queue_free)
	voice.play()
