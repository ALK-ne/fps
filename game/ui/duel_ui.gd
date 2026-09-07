class_name DuelUI
extends CanvasLayer

signal command(action: String, argument: Variant)
var root: Control
var panel: PanelContainer
var content: VBoxContainer
var status_label: Label
var hud: Label
var crosshair: Label
var health_label: Label
var inventory_label: Label
var prompt_label: Label
var wheel: DuelWheel
var screen: String = "menu"
var inputs: Dictionary = {}
var buttons: Array[Button] = []
var draft: Dictionary = {}
var previous: Dictionary = {}
var settings: SettingsStore
var config: GameConfig
var video_deadline: int = 0
var rebind_action: String = ""
var rebind_pending: int = 0

func build(cfg: GameConfig, store: SettingsStore) -> void:
	config = cfg
	settings = store
	root = Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var theme_value := Theme.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Yu Gothic UI", "Meiryo", "sans-serif"])
	theme_value.default_font = font
	theme_value.default_font_size = 24
	root.theme = theme_value
	add_child(root)
	hud = Label.new()
	hud.position = Vector2(40, 25)
	hud.add_theme_font_size_override("font_size", 26)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(hud)
	hud.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	hud.position.y = 25
	hud.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	health_label = label(root, "", 32)
	health_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	health_label.offset_left = 40
	health_label.offset_right = 560
	health_label.offset_top = -130
	health_label.offset_bottom = -30
	inventory_label = label(root, "", 24)
	inventory_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	inventory_label.offset_left = -670
	inventory_label.offset_right = -50
	inventory_label.offset_top = -155
	inventory_label.offset_bottom = -40
	inventory_label.custom_minimum_size.x = 620
	inventory_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	prompt_label = label(root, "", 23)
	prompt_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	prompt_label.offset_left = -800
	prompt_label.offset_right = 800
	prompt_label.offset_top = -215
	prompt_label.offset_bottom = -165
	prompt_label.custom_minimum_size.x = 1600
	prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wheel = DuelWheel.new()
	wheel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	wheel.position = Vector2(-260, -260)
	wheel.size = Vector2(520, 520)
	root.add_child(wheel)
	wheel.hide()
	crosshair = Label.new()
	crosshair.text = "+"
	crosshair.add_theme_font_size_override("font_size", 36)
	crosshair.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	crosshair.position = Vector2(-12, -25)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(crosshair)
	crosshair.hide()
	for item in [health_label, inventory_label, prompt_label]: item.hide()

func base(title: String, subtitle: String = "") -> void:
	for item in [health_label, inventory_label, prompt_label, wheel]: item.hide()
	if is_instance_valid(panel):
		root.remove_child(panel)
		panel.queue_free()
	inputs.clear()
	buttons.clear()
	panel = PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.position = Vector2(-530, -430)
	panel.custom_minimum_size.x = 1060
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.09, 0.15, 0.97)
	style.set_corner_radius_all(16)
	style.content_margin_left = 36
	style.content_margin_right = 36
	style.content_margin_top = 26
	style.content_margin_bottom = 26
	panel.add_theme_stylebox_override("panel", style)
	root.add_child(panel)
	content = VBoxContainer.new()
	content.add_theme_constant_override("separation", 14)
	panel.add_child(content)
	label(content, "ARENA DUEL  /  PROTOTYPE", 18).modulate = Color("41d9ff")
	label(content, title, 42)
	if not subtitle.is_empty(): label(content, subtitle, 22)
	status_label = label(content, "", 21)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.modulate = Color("ffb45b")
	crosshair.hide()

func menu(can_resume: bool) -> void:
	screen = "menu"
	hud.text = ""
	base("動いて、拾って、撃ち合おう。", "1対1の小さなアリーナ。10ラウンド先取で勝利。")
	if can_resume: button(content, "前の試合へ復帰", "resume")
	for item in [["対戦する", "connection"], ["練習する", "practice"], ["設定", "settings"], ["終了", "quit"]]: button(content, item[0], item[1])
	label(content, "90秒 / ラウンド  ·  キーボード＆マウス", 20)

func connection() -> void:
	screen = "connection"
	base("友だちと対戦", "ホストIPを入力して部屋を作り、招待コードを相手へ共有します。")
	field("address", "ホストIP / 補助ネットワークIP", "127.0.0.1")
	button(content, "部屋を作る", "host")
	field("invite", "招待コード", "")
	button(content, "コードをコピー", "copy")
	button(content, "コードで参加", "join")
	label(content, "直接接続できない場合は、両PCで補助ネットワークを接続してください。", 20)
	button(content, "戻る", "menu")

func selection(session: DuelSession) -> void:
	screen = "selection"
	base("開始地点を選ぶ", "相手と同じ地点・近すぎる地点は選べません。")
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 100)
	content.add_child(grid)
	for row in 3:
		for side in 2:
			var id := side * 3 + row
			var b := button(grid, "%s %d" % ["LEFT" if side == 0 else "RIGHT", row + 1], "spawn", id)
			b.custom_minimum_size = Vector2(440, 100)
			b.set_meta("spawn", id)
			buttons.append(b)
	button(content, "離れる", "leave_confirm")
	update_selection(session)

func update_selection(session: DuelSession) -> void:
	var d := session.director
	var slot := d.first_slot if session.phase == 2 else 1 - d.first_slot
	status_label.text = "%sが選択中  残り %.1f秒" % ["あなた" if slot == session.local_slot else "相手", maxf(0, (d.deadline_tick - session.tick) / 60.0)]
	for b in buttons:
		var id: int = b.get_meta("spawn")
		b.disabled = not d.allowed(session.local_slot, id)
		b.modulate = Color("ffb45b") if id in d.selected_spawn else Color.WHITE

func playing() -> void:
	screen = "playing"
	if is_instance_valid(panel): panel.hide()
	crosshair.show()
	for item in [health_label, inventory_label, prompt_label]: item.show()

func pause(practice_mode: bool) -> void:
	screen = "pause"
	base("ポーズ", "オンラインでは世界が進行し、被弾します。" if not practice_mode else "練習を一時停止しています。")
	button(content, "続ける", "continue")
	if practice_mode:
		for item in [["同じ配置でリセット", "reset"], ["配置を再抽選", "reroll"], ["固定／移動標的を切り替え", "target"]]: button(content, item[0], item[1])
	button(content, "設定", "settings")
	button(content, "メニューへ戻る", "leave_confirm")

func waiting(message: String) -> void:
	screen = "waiting"
	base("接続・復帰を待っています", message)
	button(content, "戻る", "leave_confirm")

func results(session: DuelSession) -> void:
	screen = "results"
	var state := session.store.state
	base("あなたの勝利" if state.match_winner == session.local_slot else "試合終了", "%d  —  %d" % [state.scores[session.local_slot], state.scores[1 - session.local_slot]])
	status_label.text = session.status
	label(content, "再戦同意  %s / %s" % [str(session.rematch_ready[0]), str(session.rematch_ready[1])], 22)
	button(content, "再戦に同意", "rematch")
	button(content, "戻る", "menu")

func confirmation() -> void:
	screen = "confirm"
	base("試合を離れますか？", "対戦を離れると接続が切れ、復帰待機の対象になります。")
	button(content, "離れる", "menu")
	button(content, "戻る", "continue")

func settings_screen() -> void:
	screen = "settings"
	draft = settings.values.duplicate(true)
	base("設定")
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(980, 460)
	content.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	for spec in [["マウス感度", "sensitivityDegreesPerPixel", 0.01, 1.0, 0.01], ["ADS感度倍率", "adsSensitivityMultiplier", 0.1, 2.0, 0.05], ["視野角", "verticalFov", 55, 100, 1], ["マスター音量", "masterVolume", 0, 1, 0.01], ["効果音音量", "sfxVolume", 0, 1, 0.01]]:
		var key: String = spec[1]
		var row := HBoxContainer.new()
		list.add_child(row)
		label(row, spec[0], 23).custom_minimum_size.x = 250
		var slider := HSlider.new()
		slider.min_value = spec[2]
		slider.max_value = spec[3]
		slider.step = spec[4]
		slider.value = draft[key]
		slider.custom_minimum_size.x = 500
		row.add_child(slider)
		var number := label(row, "%.2f" % slider.value, 23)
		number.custom_minimum_size.x = 90
		slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		slider.value_changed.connect(func(v): draft[key] = v; number.text = "%.2f" % v)
	for key in ["adsToggle", "crouchToggle"]:
		var check := CheckButton.new()
		check.text = "ADSを切り替え式にする" if key == "adsToggle" else "しゃがみを切り替え式にする"
		check.button_pressed = draft[key]
		check.toggled.connect(func(v): draft[key] = v)
		list.add_child(check)
	for spec in [["画面モード", "windowMode", ["window", "borderless", "fullscreen"]], ["画質", "quality", ["low", "medium", "high"]], ["FPS上限", "fpsCap", [30, 60, 90, 120, 144, 165, 240, 0]], ["解像度", "resolution", [[1280, 720], [1600, 900], [1920, 1080], [2560, 1440]]]]:
		var row := HBoxContainer.new()
		list.add_child(row)
		label(row, spec[0], 23).custom_minimum_size.x = 250
		var option := OptionButton.new()
		var key: String = spec[1]
		var choices: Array = spec[2]
		for i in choices.size():
			option.add_item(str(choices[i]))
			if str(choices[i]) == str(draft[key]): option.select(i)
		option.item_selected.connect(func(i): draft[key] = choices[i])
		row.add_child(option)
	for key in draft["keys"]:
		if key != "pause": inputs["key_" + key] = button(list, key + "  [" + OS.get_keycode_string(int(draft["keys"][key])) + "]", "rebind", key)
	button(content, "適用", "apply_settings")
	button(content, "既定値", "default_settings")
	button(content, "戻る", "settings_back")

func rebind(event: InputEvent) -> bool:
	if rebind_action.is_empty() or not event is InputEventKey or not event.pressed or event.echo: return false
	if event.physical_keycode == KEY_ESCAPE:
		rebind_action = ""
		return true
	var code: int = event.physical_keycode
	for key in draft["keys"]:
		if key == rebind_action or int(draft["keys"][key]) != code: continue
		if rebind_pending != code:
			rebind_pending = code
			status_label.text = key + "と交換します。同じキーをもう一度押して確定。"
			return true
		draft["keys"][key] = draft["keys"][rebind_action]
		inputs["key_" + key].text = key + "  [" + OS.get_keycode_string(int(draft["keys"][key])) + "]"
	draft["keys"][rebind_action] = code
	inputs["key_" + rebind_action].text = rebind_action + "  [" + OS.get_keycode_string(code) + "]"
	rebind_action = ""
	rebind_pending = 0
	return true

func apply_settings() -> void:
	previous = settings.values.duplicate(true)
	settings.values = draft.duplicate(true)
	settings.apply()
	video_deadline = Time.get_ticks_msec() + 15000
	base("この設定を保存しますか？", "15秒以内に確認しない場合、以前の設定へ戻ります。")
	button(content, "保存する", "confirm_settings")
	button(content, "元に戻す", "revert_settings")

func update_hud(view: WorldView, router: InputRouter, practice: PracticeDirector, session: DuelSession) -> void:
	if screen != "playing": return
	var player: PlayerState = view.simulation.players[view.local_slot]
	var inv := player.inventory
	var gun := inv.active()
	var weapon := "素手" if gun.is_empty() else "%s  %d / %d" % [["RIFLE", "SHOTGUN", "PISTOL"][int(gun.kind) - 1], gun.magazine, inv.reserve[int(gun.kind) - 1]]
	var header := ""
	if practice != null: header = "PRACTICE  %s標的  HIT %d / HEAD %d  TTK %.2fs" % ["移動" if practice.moving else "固定", practice.hits, practice.head_hits, practice.last_ttk_ms / 1000.0]
	elif session != null: header = "ROUND %d   %d — %d   %.1fs" % [session.store.state.round, session.store.state.scores[view.local_slot], session.store.state.scores[1 - view.local_slot], maxf(0, (session.director.deadline_tick - session.tick) / 60.0)]
	var prompt := "E 拾う  /  Shift ダッシュ  /  Space ジャンプ  /  Ctrl スライド  /  Esc メニュー"
	if not router.captured: prompt = "クリックして操作を再開"
	elif not view.simulation.pickup.target(player).is_empty(): prompt = "[E] 拾う  /  2丁所持時は1秒長押しで交換"
	if player.action in [1, 2, 3, 6]: prompt = "%s  %.1fs" % [{1: "武器切替", 2: "リロード", 3: "回復中", 6: "交換中"}[player.action], maxf(0, (player.action_end_tick - view.simulation.tick) / 60.0)]
	elif player.action in [4, 5]: prompt = "左長押しで軌道、離して投げる / Gで解除"
	if not router.wheel.is_empty():
		var names: Array = ["体力小", "体力全", "アーマー小", "アーマー全"] if router.wheel == "heal" else ["フラグ", "焼夷"]
		prompt = "◀ %s ▶ キーを離して選択" % names[router.wheel_choice - 1]
	hud.text = header
	health_label.text = "HP  %d\nARMOR  %d / %d" % [ceili(player.hp_milli / 1000.0), ceili(player.armor_milli / 1000.0), player.armor_max / 1000]
	health_label.modulate = Color("41d9ff") if player.armor_milli > 0 else Color("ffb45b")
	inventory_label.text = "%s\n回復 [5] %d  [6] %d  [7] %d  [8] %d\n投擲 フラグ %d / 焼夷 %d" % [weapon, inv.heals[0], inv.heals[1], inv.heals[2], inv.heals[3], inv.grenades[0], inv.grenades[1]]
	prompt_label.text = prompt
	wheel.visible = not router.wheel.is_empty()
	if wheel.visible: wheel.configure(["体力小", "体力全", "アーマー小", "アーマー全"] if router.wheel == "heal" else ["フラグ", "焼夷"], inv.heals if router.wheel == "heal" else inv.grenades, router.wheel_choice)
	crosshair.text = "×" if Time.get_ticks_msec() < view.hit_until else "+"
	crosshair.modulate = Color("ffd66e") if view.head_hit and Time.get_ticks_msec() < view.hit_until else Color.WHITE

func field(key: String, placeholder: String, value: String) -> void:
	var field_value := LineEdit.new()
	field_value.placeholder_text = placeholder
	field_value.text = value
	field_value.custom_minimum_size.y = 55
	content.add_child(field_value)
	inputs[key] = field_value

func label(parent: Node, text: String, size_value: int) -> Label:
	var result := Label.new()
	result.text = text
	result.add_theme_font_size_override("font_size", size_value)
	result.autowrap_mode = TextServer.AUTOWRAP_OFF
	result.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(result)
	return result

func button(parent: Node, text: String, action: String, argument: Variant = null) -> Button:
	var result := Button.new()
	result.text = text
	result.custom_minimum_size.y = 58
	result.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	result.pressed.connect(func(): command.emit(action, argument))
	parent.add_child(result)
	return result
