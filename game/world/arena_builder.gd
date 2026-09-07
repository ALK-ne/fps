class_name ArenaBuilder
extends Node3D

var boxes: Array = []
var bodies: Array[StaticBody3D] = []
var config: GameConfig
var world_material: ShaderMaterial

func build(cfg: GameConfig) -> void:
	config = cfg
	world_material = ShaderMaterial.new()
	world_material.shader = load("res://presentation/toon.gdshader")
	_add_box("floor", Vector3(0, -0.25, 0), Vector3(40, 0.5, 28), Color("26344d"))
	for sign_value in [-1, 1]:
		_add_box("boundary_x", Vector3(sign_value * 20, 2, 0), Vector3(0.5, 4, 28), Color("465875"))
		_add_box("boundary_z", Vector3(0, 2, sign_value * 14), Vector3(40, 4, 0.5), Color("465875"))
		for z in cfg.arena.spawnZ:
			var pocket: Dictionary = cfg.arena.pockets
			_add_box("pocket_front", Vector3(sign_value * pocket.frontAbsX, 1.5, z), vec(pocket.frontSize), Color("465875"))
			for side in [-1, 1]:
				_add_box("pocket_side", Vector3(sign_value * pocket.sideAbsX, 1.5, z + side * pocket.sideOffsetZ), vec(pocket.sideSize), Color("465875"))
	for obstacle in cfg.arena.obstacles:
		_add_box(obstacle.id, vec(obstacle.position), vec(obstacle.size), Color("465875") if obstacle.size[1] > 1 else Color("587494"))
	# Thin floor inlays show routes without adding collision or radar information.
	for x in [-10, 10]:
		var strip := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.07, 0.01, 25)
		strip.mesh = mesh
		strip.position = Vector3(x, 0.008, 0)
		strip.material_override = material(Color("41d9ff"))
		add_child(strip)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -30, 0)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	add_child(sun)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("111827")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color("9aafd0")
	environment.environment.ambient_light_energy = 0.65
	add_child(environment)

func _add_box(id: String, pos: Vector3, size: Vector3, color: Color) -> void:
	var body := StaticBody3D.new()
	body.name = id + str(bodies.size())
	body.position = pos
	body.collision_layer = 1
	body.collision_mask = 0
	var collider := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collider.shape = shape
	body.add_child(collider)
	var instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	instance.mesh = mesh
	instance.material_override = material(color)
	body.add_child(instance)
	body.set_meta("surface_id", bodies.size())
	add_child(body)
	bodies.append(body)
	boxes.append(AABB(pos - size / 2, size))

func material(color: Color) -> ShaderMaterial:
	var m: ShaderMaterial = world_material.duplicate()
	m.set_shader_parameter("base_color", color)
	return m

static func vec(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])

func spawn_position(id: int) -> Vector3:
	return Vector3(-16 if id < 3 else 16, 0.05, config.arena.spawnZ[id % 3])

func spawn_yaw(id: int) -> float:
	return deg_to_rad(-90 if id < 3 else 90)
