class_name AppContext
extends Node

var config := GameConfig.new()
var options := LaunchOptions.new()
var instance_lock := InstanceLock.new()
var profile := DuelProfile.new()
var settings := SettingsStore.new()
var clock := DuelClock.new()
var router := InputRouter.new()
var ui := DuelUI.new()
var world: WorldView
var practice: PracticeDirector
var session: DuelSession
var frame := InputFrame.new()
var tick: int = 0
var menu_return: String = "menu"
var last_phase: int = -1
var slow_sections: Dictionary = {}

func start() -> void:
	_boot_trace("arguments")
	var r := options.parse(OS.get_cmdline_user_args())
	if r.ok: r = instance_lock.acquire(options.instance_lock_port)
	_boot_trace("profile")
	if r.ok: r = profile.open(options.profile)
	_boot_trace("configuration")
	if r.ok: r = config.load_data()
	if not r.ok:
		push_error(r.error_code + ": " + r.details)
		ui.free()
		get_tree().quit(1)
		return
	settings.load_settings(profile, config)
	_boot_trace("settings")
	settings.apply()
	router.configure(settings)
	add_child(ui)
	ui.build(config, settings)
	_boot_trace("menu")
	ui.command.connect(_command)
	ui.menu(profile.files.load_ab(profile.root + "/current-match.json").ok)
	if options.scenario == "resume":
		_network()
		r = session.restore()
		if not r.ok: _error(r)
	elif options.role == "practice": _practice()
	elif options.role in ["host", "guest"]:
		ui.connection()
		_network()
		var endpoint := options.endpoint.rsplit(":", true, 1)
		if options.role == "host":
			r = session.create_room(endpoint[0], int(endpoint[1]))
			if OS.is_debug_build() and not options.scenario.is_empty():
				var file := FileAccess.open("res://../artifacts/scenario-invite.txt", FileAccess.WRITE)
				if file != null: file.store_string(DuelAuth.invitation(session.invitation_data))
		else: r = session.join_room(FileAccess.get_file_as_string("res://../artifacts/scenario-invite.txt"))
		if not r.ok: _error(r)
	get_window().focus_exited.connect(func(): router.capture(false))
	if OS.is_debug_build() and not options.scenario.is_empty():
		var scenario = load("res://tests/scenario_runner.gd").new()
		scenario.app = self
		add_child(scenario)
	_boot_trace("ready")

func _boot_trace(stage: String) -> void:
	if OS.is_debug_build(): print(JSON.stringify({"boot_stage": stage, "ms": Time.get_ticks_msec()}))

func _world() -> void:
	if is_instance_valid(world):
		remove_child(world)
		world.queue_free()
	world = WorldView.new()
	add_child(world)
	world.build(config)

func _practice() -> void:
	_close_session()
	_world()
	practice = PracticeDirector.new()
	practice.world = world
	practice.seed_value = options.seed_value
	practice.reset()
	router.yaw = world.simulation.players[0].yaw
	router.pitch = 0
	router.capture(true)
	ui.playing()

func _network() -> void:
	_close_session()
	practice = null
	_world()
	world.hide()
	session = DuelSession.new()
	session.setup(config, profile, clock, world)
	session.status_changed.connect(func(message):
		if is_instance_valid(ui.status_label): ui.status_label.text = message)
	session.phase_changed.connect(_phase_changed)
	session.game_events.connect(world.show_events)
	session.world_received.connect(func(_data):
		router.yaw = world.simulation.players[session.local_slot].yaw
		router.pitch = world.simulation.players[session.local_slot].pitch)
	session.store.files.fault_point = options.test_fault
	last_phase = -1

func _phase_changed() -> void:
	if session == null: return
	var phase := session.phase
	if phase == last_phase and ui.screen != "results": return
	last_phase = phase
	match phase:
		2, 3:
			router.capture(false)
			world.hide()
			ui.selection(session)
		4, 5:
			world.show()
			ui.playing()
			router.capture(phase == 5)
		7, 9, 10:
			router.capture(false)
			ui.waiting(session.status)
		8:
			router.capture(false)
			ui.results(session)

func _command(action: String, argument: Variant) -> void:
	match action:
		"practice": _practice()
		"connection": ui.connection()
		"host":
			var address: String = ui.inputs.address.text.strip_edges()
			_network()
			var r := session.create_room(address)
			if r.ok: ui.inputs.invite.text = DuelAuth.invitation(session.invitation_data)
			else: _error(r)
		"join":
			var code: String = ui.inputs.invite.text
			_network()
			var r := session.join_room(code)
			if not r.ok: _error(r)
		"copy": DisplayServer.clipboard_set(ui.inputs.invite.text)
		"spawn": session.choose_spawn(session.local_slot, int(argument))
		"resume":
			_network()
			var r := session.restore()
			ui.waiting(session.status)
			if not r.ok: _error(r)
		"settings":
			menu_return = "pause" if practice != null or session != null else "menu"
			router.capture(false)
			ui.settings_screen()
		"rebind":
			ui.rebind_action = str(argument)
			ui.status_label.text = "新しいキーを押してください。Escで取り消し。"
		"apply_settings": ui.apply_settings()
		"confirm_settings":
			ui.video_deadline = 0
			var r := settings.save()
			if not r.ok: _error(r)
			router.configure(settings)
			ui.settings_screen()
		"revert_settings":
			ui.video_deadline = 0
			settings.values = ui.previous.duplicate(true)
			settings.apply()
			ui.settings_screen()
		"default_settings":
			ui.draft = config.rules.settings.duplicate(true)
			ui.draft["keys"] = config.defaults.duplicate(true)
			ui.draft.schema = 1
			ui.apply_settings()
		"settings_back":
			if menu_return == "pause": ui.pause(practice != null)
			else: ui.menu(profile.files.load_ab(profile.root + "/current-match.json").ok)
		"continue":
			if session != null and session.phase in [2, 3]: ui.selection(session)
			elif session != null and session.phase in [7, 9, 10]: ui.waiting(session.status)
			else:
				ui.playing()
				router.capture(true)
		"reset", "reroll":
			practice.reset(action == "reroll")
			router.yaw = world.simulation.players[0].yaw
			router.pitch = 0
			ui.playing()
			router.capture(true)
		"target":
			practice.moving = not practice.moving
			ui.playing()
			router.capture(true)
		"leave_confirm":
			router.capture(false)
			ui.confirmation()
		"rematch":
			session.rematch()
			ui.results(session)
		"menu":
			_close_session()
			practice = null
			router.capture(false)
			if is_instance_valid(world): world.hide()
			ui.menu(profile.files.load_ab(profile.root + "/current-match.json").ok)
		"quit":
			_close_session()
			get_tree().quit()

func _input(event: InputEvent) -> void:
	router.viewport_size = get_viewport().get_visible_rect().size
	if ui.rebind(event):
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("pause") and (practice != null or session != null):
		if ui.screen == "playing":
			router.capture(false)
			ui.pause(practice != null)
		elif ui.screen == "pause": _command("continue", null)
		get_viewport().set_input_as_handled()
		return
	if ui.screen != "playing": return
	if not router.captured and event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		router.capture(true)
		get_viewport().set_input_as_handled()
		return
	router.handle(event)

func _physics_process(_delta: float) -> void:
	if config.rules.is_empty(): return
	var started_us := Time.get_ticks_usec()
	tick += 1
	frame = router.sample(session.tick if session != null else tick)
	if practice != null and ui.screen == "playing": world.show_events(practice.step(frame, tick))
	elif session != null: session.physics(frame)
	_trace_slow("physics", started_us)

func _process(delta: float) -> void:
	if config.rules.is_empty(): return
	var started_us := Time.get_ticks_usec()
	if session != null:
		session.poll()
		_trace_slow("network", started_us)
		started_us = Time.get_ticks_usec()
		if ui.screen == "selection": ui.update_selection(session)
		if ui.screen == "waiting" and session.local_continuous and not session.recovery.observation.is_empty(): ui.status_label.text = session.status + "\n残り %.1f秒" % (session.recovery.remaining_ms() / 1000.0)
	if is_instance_valid(world) and world.visible:
		world.present(settings, frame, delta)
		ui.update_hud(world, router, practice, session)
	_trace_slow("presentation", started_us)
	if ui.video_deadline > 0 and Time.get_ticks_msec() >= ui.video_deadline: _command("revert_settings", null)

func _trace_slow(section: String, started_us: int) -> void:
	if OS.is_debug_build() and Time.get_ticks_usec() - started_us >= 250000:
		# Diagnostics must not add synchronous console IO to a delayed frame.
		var milliseconds := (Time.get_ticks_usec() - started_us) / 1000
		slow_sections[section] = maxi(int(slow_sections.get(section, 0)), milliseconds)

func _error(result: DuelResult) -> void:
	if is_instance_valid(ui.status_label): ui.status_label.text = result.error_code + " " + result.details
	push_warning(result.error_code)

func _close_session() -> void:
	if session != null: session.close()
	session = null
