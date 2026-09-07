class_name DuelProfile
extends RefCounted

var root: String
var player_id: PackedByteArray
var boot_id: PackedByteArray = DuelIds.random_bytes(16)
var files := AtomicFiles.new()

func open(name_value: String) -> DuelResult:
	var regex := RegEx.new()
	regex.compile("^[a-zA-Z0-9_-]{1,32}$")
	if regex.search(name_value) == null: return DuelResult.failure("INVALID_PROFILE")
	root = "user://profiles/" + name_value
	var identity := files.load_ab(root + "/identity.json")
	if identity.ok:
		if not identity.value.value is PackedByteArray or identity.value.value.size() != 16: return DuelResult.failure("STORE_CORRUPT")
		player_id = identity.value.value
	elif identity.error_code == "NOT_FOUND":
		player_id = DuelIds.random_bytes(16)
		return files.save_ab(root + "/identity.json", player_id)
	else: return identity
	return DuelResult.success()
