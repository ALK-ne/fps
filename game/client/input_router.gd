class_name InputRouter
extends RefCounted

var settings: SettingsStore
var yaw: float = 0
var pitch: float = 0
var seq: int = 0
var pending: Array = []
var captured: bool = false
var ads_toggle: bool = false
var crouch_toggle: bool = false
var pressed_at: Dictionary = {}
var wheel: String = ""
var wheel_choice: int = 1
var released_throw: bool = false
var viewport_size := Vector2(1920, 1080)

func configure(store: SettingsStore) -> void:
	settings = store
	for key in store.values.keys:
		if InputMap.has_action(key): InputMap.erase_action(key)
		InputMap.add_action(key)
		var e := InputEventKey.new()
		e.physical_keycode = int(store.values.keys[key])
		InputMap.action_add_event(key, e)
	for pair in [["fire", MOUSE_BUTTON_LEFT], ["ads", MOUSE_BUTTON_RIGHT]]:
		if InputMap.has_action(pair[0]): InputMap.erase_action(pair[0])
		InputMap.add_action(pair[0])
		var e := InputEventMouseButton.new()
		e.button_index = pair[1]
		InputMap.action_add_event(pair[0], e)

func capture(value: bool) -> void:
	captured = value
	pending.clear()
	pressed_at.clear()
	wheel = ""
	ads_toggle = false
	crouch_toggle = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if value else Input.MOUSE_MODE_VISIBLE

func handle(event: InputEvent) -> void:
	if not captured: return
	if event is InputEventMouseMotion:
		if not wheel.is_empty():
			var vector: Vector2 = event.position - viewport_size / 2
			var angle := fposmod(vector.angle() + PI / 4, TAU)
			wheel_choice = int(angle / (TAU / (4 if wheel == "heal" else 2))) + 1
		else:
			var ads := Input.is_action_pressed("ads") or ads_toggle
			var factor: float = settings.values.sensitivityDegreesPerPixel * (settings.values.adsSensitivityMultiplier if ads else 1.0)
			yaw -= deg_to_rad(event.relative.x * factor)
			pitch = clampf(pitch - deg_to_rad(event.relative.y * factor), deg_to_rad(-89), deg_to_rad(89))
	if event.is_echo(): return
	for key in ["heal", "grenade"]:
		if event.is_action_pressed(key): pressed_at[key] = Time.get_ticks_msec()
		if event.is_action_released(key) and pressed_at.has(key):
			var duration: int = Time.get_ticks_msec() - int(pressed_at[key])
			if duration >= 200: pending.append({"kind": "select_" + key, "argument": wheel_choice})
			else: pending.append({"kind": key, "argument": 0})
			pressed_at.erase(key)
			wheel = ""
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if not wheel.is_empty(): return
	for key in ["jump", "reload", "interact", "melee", "fire"]:
		if event.is_action_pressed(key): pending.append({"kind": key, "argument": 0})
	for i in 2:
		if event.is_action_pressed("weapon_%d" % (i + 1)): pending.append({"kind": "switch", "argument": i})
	for i in 4:
		if event.is_action_pressed("heal_%d" % (i + 1)): pending.append({"kind": "heal", "argument": i + 1})
	if event.is_action_released("fire"): pending.append({"kind": "throw", "argument": 0})
	if event.is_action_pressed("ads") and settings.values.adsToggle: ads_toggle = not ads_toggle
	if event.is_action_pressed("crouch") and settings.values.crouchToggle: crouch_toggle = not crouch_toggle

func sample(tick: int) -> InputFrame:
	seq += 1
	var f := InputFrame.new()
	f.seq = seq
	f.sample_tick = tick
	f.yaw = yaw
	f.pitch = pitch
	if not captured: return f
	for key in pressed_at:
		if Time.get_ticks_msec() - int(pressed_at[key]) >= 200 and wheel.is_empty():
			wheel = key
			wheel_choice = 1
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if not wheel.is_empty(): return f
	f.axes = Input.get_vector("left", "right", "forward", "back")
	if Input.is_action_pressed("fire"): f.held_buttons |= InputFrame.FIRE
	if (ads_toggle if settings.values.adsToggle else Input.is_action_pressed("ads")): f.held_buttons |= InputFrame.ADS
	if Input.is_action_pressed("sprint"): f.held_buttons |= InputFrame.SPRINT
	if (crouch_toggle if settings.values.crouchToggle else Input.is_action_pressed("crouch")): f.held_buttons |= InputFrame.CROUCH
	if Input.is_action_pressed("interact"): f.held_buttons |= InputFrame.INTERACT
	f.actions = pending.duplicate(true)
	pending.clear()
	return f
