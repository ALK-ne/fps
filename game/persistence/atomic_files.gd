class_name AtomicFiles
extends RefCounted

signal fault_reached(point: String)
var fault_point: String = ""

func _fault(point: String) -> void:
	fault_reached.emit(point)
	if OS.is_debug_build() and fault_point == point:
		print(JSON.stringify({"fault_point": point, "pid": OS.get_process_id()}))
		# Stop only this test process at an observable, exact persistence boundary.
		OS.kill(OS.get_process_id())

func write_new(path: String, bytes: PackedByteArray) -> DuelResult:
	if FileAccess.file_exists(path):
		return DuelResult.success() if FileAccess.get_file_as_bytes(path) == bytes else DuelResult.failure("HISTORY_FORK")
	return _write(path, bytes, false)

func _write(path: String, bytes: PackedByteArray, replace: bool) -> DuelResult:
	var err := DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if err != OK: return DuelResult.failure("STORE_WRITE_FAILED", str(err))
	_fault("before_write")
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if file == null: return DuelResult.failure("STORE_WRITE_FAILED", str(FileAccess.get_open_error()))
	var half := bytes.size() / 2
	file.store_buffer(bytes.slice(0, half))
	_fault("partial_write")
	file.store_buffer(bytes.slice(half))
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK: return DuelResult.failure("STORE_WRITE_FAILED")
	_fault("after_flush")
	if FileAccess.get_file_as_bytes(path + ".tmp") != bytes: return DuelResult.failure("STORE_WRITE_FAILED", "read-back")
	# A/B files always retain the other generation if replacement is interrupted.
	if replace and FileAccess.file_exists(path):
		if DirAccess.remove_absolute(path) != OK: return DuelResult.failure("STORE_WRITE_FAILED", "remove generation")
	if DirAccess.rename_absolute(path + ".tmp", path) != OK: return DuelResult.failure("STORE_WRITE_FAILED", "rename")
	_fault("after_rename")
	return DuelResult.success() if FileAccess.get_file_as_bytes(path) == bytes else DuelResult.failure("STORE_WRITE_FAILED", "final read-back")

func save_ab(path: String, value: Variant) -> DuelResult:
	var old := load_ab(path)
	if not old.ok and old.error_code != "NOT_FOUND": return old
	var generation: int = int(old.value.generation) + 1 if old.ok else 1
	var body := CanonicalCodec.encode({"generation": generation, "value": value})
	var wrapped := body.duplicate()
	wrapped.append_array(DuelIds.digest(body))
	return _write(path + (".a" if generation % 2 else ".b"), wrapped, true)

func load_ab(path: String) -> DuelResult:
	var found := false
	var best: Dictionary = {}
	for suffix in [".a", ".b"]:
		if not FileAccess.file_exists(path + suffix): continue
		found = true
		var bytes := FileAccess.get_file_as_bytes(path + suffix)
		if bytes.size() < 33 or bytes.size() > 65568: continue
		var body := bytes.slice(0, bytes.size() - 32)
		if DuelIds.digest(body) != bytes.slice(bytes.size() - 32): continue
		var decoded := CanonicalCodec.decode(body, 65536)
		if not decoded.ok or not decoded.value is Dictionary: continue
		var d: Dictionary = decoded.value
		if not d.has("generation") or not d.has("value") or not d.generation is int or d.generation < 1: continue
		if best.is_empty() or d.generation > best.generation: best = d
	if best.is_empty(): return DuelResult.failure("STORE_CORRUPT" if found else "NOT_FOUND")
	return DuelResult.success(best)
