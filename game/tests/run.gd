extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var total := 0
	var failed := 0
	var records: Array = []
	var directory := DirAccess.open("res://tests")
	var files := directory.get_files()
	files.sort()
	for filename in files:
		if not filename.begins_with("test_") or not filename.ends_with(".gd"): continue
		var script = load("res://tests/" + filename)
		if script == null or not script.can_instantiate():
			failed += 1
			continue
		var suite = script.new()
		var count := 0
		for method in suite.get_method_list():
			if not str(method.name).begins_with("test_"): continue
			count += 1
			total += 1
			var assertions := DuelAssertions.new()
			await suite.call(method.name, assertions)
			if not assertions.failures.is_empty() or assertions.checks == 0: failed += 1
			var record := {"test": filename + ":" + str(method.name), "checks": assertions.checks, "failures": assertions.failures, "pass": assertions.failures.is_empty() and assertions.checks > 0}
			records.append(record)
			print(JSON.stringify(record))
		if count == 0: failed += 1
	print(JSON.stringify({"suite": "godot_unit", "tests": total, "failed": failed, "engine": Engine.get_version_info().string}))
	quit(1 if failed > 0 or total == 0 else 0)
