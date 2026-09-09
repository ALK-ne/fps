class_name ClosedIndex
extends RefCounted

const SEGMENT_CAP := 4096
var root: String
var files := AtomicFiles.new()

func _manifest() -> DuelResult:
	var saved := files.load_ab(root + "/manifest")
	if saved.error_code == "NOT_FOUND": return DuelResult.success({"sealed": 0, "tail_generation": 0, "tail_count": 0, "total": 0})
	if not saved.ok: return saved
	var value: Variant = saved.value.value
	if not value is Dictionary or not StoreSchema.exact(value, ["sealed", "tail_generation", "tail_count", "total"]): return DuelResult.failure("STORE_CORRUPT")
	for key in value:
		if not StoreSchema.integer(value[key]): return DuelResult.failure("STORE_CORRUPT")
	if value.tail_count >= SEGMENT_CAP or value.total != value.sealed * SEGMENT_CAP + value.tail_count: return DuelResult.failure("STORE_CORRUPT")
	return DuelResult.success(value)

func _read(path: String) -> DuelResult:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() < 33 or bytes.size() > 1048576: return DuelResult.failure("STORE_CORRUPT")
	var body := bytes.slice(0, bytes.size() - 32)
	if DuelIds.digest(body) != bytes.slice(bytes.size() - 32): return DuelResult.failure("STORE_CORRUPT")
	var decoded := CanonicalCodec.decode(body, 1048576)
	if not decoded.ok or not decoded.value is Array or decoded.value.size() > SEGMENT_CAP: return DuelResult.failure("STORE_CORRUPT")
	var ids: Dictionary = {}
	for entry in decoded.value:
		if not entry is Dictionary or not StoreSchema.exact(entry, ["match", "block", "result"]) or not StoreSchema.bytes(entry.match, 16) or not StoreSchema.integer(entry.block, 0, 6) or not StoreSchema.integer(entry.result, 0, 3) or ids.has(entry.match): return DuelResult.failure("STORE_CORRUPT")
		ids[entry.match] = true
	return decoded

func lookup(mid: PackedByteArray) -> DuelResult:
	var loaded := _manifest()
	if not loaded.ok: return loaded
	var manifest: Dictionary = loaded.value
	for segment in range(manifest.sealed + 1):
		var tail: bool = segment == manifest.sealed
		if tail and manifest.tail_count == 0: continue
		var path := root + ("/tail-%016d.bin" % manifest.tail_generation if tail else "/segment-%016d.bin" % segment)
		var read := _read(path)
		if not read.ok: return read
		if read.value.size() != (manifest.tail_count if tail else SEGMENT_CAP): return DuelResult.failure("STORE_CORRUPT")
		for entry in read.value:
			if entry.match == mid: return DuelResult.success(entry)
	return DuelResult.failure("NOT_FOUND")

func append(mid: PackedByteArray, block: int, result: int) -> DuelResult:
	if not StoreSchema.bytes(mid, 16) or block < 0 or block > 6 or result < 0 or result > 3: return DuelResult.failure("STORE_CORRUPT")
	var existing := lookup(mid)
	if existing.ok: return DuelResult.success()
	if existing.error_code != "NOT_FOUND": return existing
	var loaded := _manifest()
	if not loaded.ok: return loaded
	var manifest: Dictionary = loaded.value
	var entries: Array = []
	var old_tail: String = root + "/tail-%016d.bin" % manifest.tail_generation
	if manifest.tail_count > 0:
		var previous := _read(old_tail)
		if not previous.ok: return previous
		entries = previous.value
	entries.append({"match": mid, "block": block, "result": result})
	var bytes := CanonicalCodec.encode(entries)
	bytes.append_array(DuelIds.digest(bytes))
	var path: String
	manifest.tail_generation += 1
	manifest.total += 1
	if entries.size() == SEGMENT_CAP:
		path = root + "/segment-%016d.bin" % manifest.sealed
		manifest.sealed += 1
		manifest.tail_count = 0
	else:
		path = root + "/tail-%016d.bin" % manifest.tail_generation
		manifest.tail_count = entries.size()
	var written := files.write_new(path, bytes)
	if not written.ok: return written
	var saved := files.save_ab(root + "/manifest", manifest)
	if not saved.ok: return saved
	# Keep the previous tail for the other A/B manifest generation.
	var obsolete := root + "/tail-%016d.bin" % (manifest.tail_generation - 2)
	if FileAccess.file_exists(obsolete) and DirAccess.remove_absolute(obsolete) != OK: return DuelResult.failure("STORE_WRITE_FAILED")
	return DuelResult.success()

func recent_ids(limit: int = 100) -> DuelResult:
	var loaded := _manifest()
	if not loaded.ok: return loaded
	var manifest: Dictionary = loaded.value
	var recent: Dictionary = {}
	for segment in range(manifest.sealed, -1, -1):
		var tail: bool = segment == manifest.sealed
		if tail and manifest.tail_count == 0: continue
		var read := _read(root + ("/tail-%016d.bin" % manifest.tail_generation if tail else "/segment-%016d.bin" % segment))
		if not read.ok: return read
		for i in range(read.value.size() - 1, -1, -1):
			recent[read.value[i].match.hex_encode()] = true
			if recent.size() >= limit: return DuelResult.success(recent)
	return DuelResult.success(recent)

func prune_details(profile_root: String) -> DuelResult:
	var recent := recent_ids()
	if not recent.ok: return recent
	var matches_root := ProjectSettings.globalize_path(profile_root + "/matches").simplify_path()
	var directory := DirAccess.open(matches_root)
	if directory == null: return DuelResult.success()
	var pattern := RegEx.new()
	pattern.compile("^[0-9a-f]{32}$")
	directory.list_dir_begin()
	var name := directory.get_next()
	while not name.is_empty():
		if directory.current_is_dir() and pattern.search(name) != null and not recent.value.has(name):
			var entry := lookup(name.hex_decode())
			if entry.ok:
				var path := matches_root.path_join(name).simplify_path()
				var removed := _remove_owned(path, matches_root + "/")
				if not removed.ok:
					directory.list_dir_end()
					return removed
			elif entry.error_code != "NOT_FOUND":
				directory.list_dir_end()
				return entry
		name = directory.get_next()
	directory.list_dir_end()
	return DuelResult.success()

func _remove_owned(path: String, allowed_prefix: String, depth: int = 0) -> DuelResult:
	var resolved := ProjectSettings.globalize_path(path).simplify_path()
	if not resolved.begins_with(allowed_prefix) or depth > 8: return DuelResult.failure("STORE_WRITE_FAILED", "retention path boundary")
	var parent := DirAccess.open(resolved.get_base_dir())
	if parent == null or not parent.has_method("is_link") or parent.is_link(resolved): return DuelResult.failure("STORE_WRITE_FAILED", "retention link boundary")
	var directory := DirAccess.open(resolved)
	if directory == null:
		return DuelResult.success() if DirAccess.remove_absolute(resolved) == OK else DuelResult.failure("STORE_WRITE_FAILED")
	directory.list_dir_begin()
	var name := directory.get_next()
	while not name.is_empty():
		var removed := _remove_owned(resolved.path_join(name), allowed_prefix, depth + 1)
		if not removed.ok:
			directory.list_dir_end()
			return removed
		name = directory.get_next()
	directory.list_dir_end()
	return DuelResult.success() if DirAccess.remove_absolute(resolved) == OK else DuelResult.failure("STORE_WRITE_FAILED")
