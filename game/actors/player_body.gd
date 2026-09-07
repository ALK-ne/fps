class_name PlayerBody
extends CharacterBody3D

var capsule: CollisionShape3D
var avatar: Node3D
var head: Area3D
var torso: Area3D
var slot: int

func build(slot_value: int, material: Material) -> void:
	slot = slot_value
	collision_layer = 2
	collision_mask = 1
	capsule = CollisionShape3D.new()
	capsule.shape = CapsuleShape3D.new()
	capsule.shape.radius = 0.35
	capsule.shape.height = 1.8
	capsule.position.y = 0.9
	add_child(capsule)
	avatar = Node3D.new()
	add_child(avatar)
	_mesh(CapsuleMesh.new(), Vector3(0, 0.98, 0), Vector3(0.6, 0.62, 0.6), material)
	_mesh(SphereMesh.new(), Vector3(0, 1.62, 0), Vector3(0.36, 0.36, 0.36), material)
	for sign_value in [-1, 1]:
		_mesh(BoxMesh.new(), Vector3(sign_value * 0.38, 1.02, -0.1), Vector3(0.17, 0.55, 0.2), material)
		_mesh(BoxMesh.new(), Vector3(sign_value * 0.18, 0.35, 0), Vector3(0.22, 0.65, 0.24), material)
	head = _hitbox(true)
	torso = _hitbox(false)

func _mesh(mesh: Mesh, pos: Vector3, size: Vector3, material: Material) -> void:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position = pos
	instance.scale = size
	instance.material_override = material
	avatar.add_child(instance)

func _hitbox(is_head: bool) -> Area3D:
	var area := Area3D.new()
	area.collision_layer = 4
	area.collision_mask = 0
	area.set_meta("slot", slot)
	area.set_meta("head", is_head)
	var shape := CollisionShape3D.new()
	if is_head:
		shape.shape = SphereShape3D.new()
		shape.shape.radius = 0.18
		area.position.y = 1.62
	else:
		shape.shape = CapsuleShape3D.new()
		shape.shape.radius = 0.3
		shape.shape.height = 1.35
		area.position.y = 0.72
	area.add_child(shape)
	add_child(area)
	return area

func set_crouched(value: bool) -> void:
	capsule.shape.height = 1.15 if value else 1.8
	capsule.position.y = capsule.shape.height * 0.5
	head.position.y = 1.0 if value else 1.62
	torso.position.y = 0.44 if value else 0.72
	torso.scale.y = 0.6 if value else 1.0
	avatar.scale.y = 0.65 if value else 1.0

func hitbox_rids() -> Array[RID]:
	return [head.get_rid(), torso.get_rid()]

func present(state: PlayerState, local: bool) -> void:
	position = state.position
	avatar.position = Vector3.ZERO
	avatar.rotation.y = state.yaw
	avatar.visible = not local and state.hp_milli > 0
	set_crouched(state.movement.crouched)
	head.monitorable = state.hp_milli > 0
	torso.monitorable = state.hp_milli > 0
