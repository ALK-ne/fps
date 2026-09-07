class_name SettingsStore
extends RefCounted

var values: Dictionary = {}
var path: String
var files := AtomicFiles.new()
var warning: String = ""

func load_settings(profile: DuelProfile, config: GameConfig) -> void:
	path = profile.root + "/settings.json"
	values = config.rules.settings.duplicate(true)
	values["keys"] = config.defaults.duplicate(true)
	values["schema"] = 1
	var r := files.load_ab(path)
	if r.ok and r.value.value is Dictionary and r.value.value.get("schema", 0) == 1:
		for key in values:
			if r.value.value.has(key): values[key] = r.value.value[key]
	elif r.error_code != "NOT_FOUND":
		warning = "設定を読み込めなかったため既定値を使用します。"
	_validate(config)

func _validate(config: GameConfig) -> void:
	for pair in [["sensitivityDegreesPerPixel", 0.01, 1.0], ["adsSensitivityMultiplier", 0.1, 2.0], ["verticalFov", 55.0, 100.0], ["masterVolume", 0.0, 1.0], ["sfxVolume", 0.0, 1.0]]:
		var v: Variant = values[pair[0]]
		values[pair[0]] = clampf(float(v), pair[1], pair[2]) if (v is float or v is int) and is_finite(float(v)) else config.rules.settings[pair[0]]
	if values.windowMode not in ["window", "borderless", "fullscreen"]: values.windowMode = "window"
	if values.quality not in ["low", "medium", "high"]: values.quality = "medium"
	if not values.resolution is Array or values.resolution.size() != 2: values.resolution = [1280, 720]
	if not values.keys is Dictionary: values.keys = config.defaults.duplicate(true)
	for key in config.defaults:
		if not values.keys.has(key) or int(values.keys[key]) <= 0: values.keys[key] = config.defaults[key]
	if values.fpsCap not in [0, 30, 60, 90, 120, 144, 165, 240]: values.fpsCap = 120

func save() -> DuelResult:
	return files.save_ab(path, values)

func apply() -> void:
	Engine.max_fps = int(values.fpsCap)
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(0.0001, values.masterVolume * values.sfxVolume)))
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		var viewport := tree.root
		match str(values.quality):
			"low":
				viewport.msaa_3d = Viewport.MSAA_DISABLED
				viewport.scaling_3d_scale = 0.7
			"high":
				viewport.msaa_3d = Viewport.MSAA_4X
				viewport.scaling_3d_scale = 1.0
			_:
				viewport.msaa_3d = Viewport.MSAA_2X
				viewport.scaling_3d_scale = 0.85
	if DisplayServer.get_name() == "headless": return
	match str(values.windowMode):
		"fullscreen": DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		"borderless":
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
			DisplayServer.window_set_size(DisplayServer.screen_get_size())
			DisplayServer.window_set_position(DisplayServer.screen_get_position())
		_:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
			DisplayServer.window_set_size(Vector2i(maxi(1280, int(values.resolution[0])), maxi(720, int(values.resolution[1]))))
	DisplayServer.window_set_min_size(Vector2i(1280, 720))
