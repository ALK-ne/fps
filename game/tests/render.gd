extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var app := AppContext.new()
	root.add_child(app)
	app.start()
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
	DisplayServer.window_set_size(Vector2i(1280, 720))
	var output := ProjectSettings.globalize_path("res://").path_join("../artifacts/visual").simplify_path()
	DirAccess.make_dir_recursive_absolute(output)
	for name_value in ["menu", "settings", "practice", "wheel"]:
		if name_value == "settings": app._command("settings", null)
		if name_value == "practice": app._command("practice", null)
		if name_value == "wheel":
			app.router.wheel = "heal"
			app.router.wheel_choice = 2
		for i in 12: await process_frame
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		var path: String = output.path_join(name_value + ".png")
		if image.save_png(path) != OK:
			quit(1)
			return
		print("Rendered " + name_value)
	app.router.capture(false)
	quit(0)
