class_name GameConfig
extends RefCounted

var rules: Dictionary
var arena: Dictionary
var defaults: Dictionary
var spawn_pairs: Array
var rules_hash: PackedByteArray
var map_hash: PackedByteArray

func load_data() -> DuelResult:
	var manifest: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/manifest.json"))
	if not manifest is Dictionary:
		return DuelResult.failure("CONFIG_INVALID", "manifest")
	for filename in manifest.files:
		var path: String = "res://data/" + filename
		if FileAccess.get_sha256(path) != manifest.files[filename]:
			return DuelResult.failure("CONFIG_INVALID", filename)
	rules = JSON.parse_string(FileAccess.get_file_as_string("res://data/game_config.json"))
	arena = JSON.parse_string(FileAccess.get_file_as_string("res://data/arena.json"))
	defaults = JSON.parse_string(FileAccess.get_file_as_string("res://data/input_defaults.json"))
	spawn_pairs = JSON.parse_string(FileAccess.get_file_as_string("res://data/spawn_graph.json")).allowedOpponents
	rules_hash = str(manifest.files["game_config.json"]).hex_decode()
	map_hash = str(manifest.files["arena.json"]).hex_decode()
	if rules.match.wins != 10 or rules.match.recoveryMs != 60000:
		return DuelResult.failure("CONFIG_INVALID", "approved rules")
	return DuelResult.success(self)

func weapon(kind: int) -> Dictionary:
	return rules.weapons[kind - 1] if kind >= 1 and kind <= 3 else {}

func heal(kind: int) -> Dictionary:
	return rules.heals[kind - 1] if kind >= 1 and kind <= 4 else {}

func ticks(ms: float) -> int:
	return int(ceil(ms * float(rules.simulation.hz) / 1000.0))
