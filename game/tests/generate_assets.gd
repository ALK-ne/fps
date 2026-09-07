extends SceneTree

func _initialize() -> void:
	var bank := AudioBank.new()
	bank.build()
	DirAccess.make_dir_recursive_absolute("res://presentation/audio")
	for key in bank.sounds:
		var err: int = bank.sounds[key].save_to_wav("res://presentation/audio/" + key + ".wav")
		if err != OK:
			quit(1)
			return
	var notices := "# Third-party notices\n\nGodot Engine 4.7.2 Standard and its bundled libraries.\n\n"
	notices += Engine.get_license_text() + "\n\n"
	notices += "## Copyright information\n\n" + JSON.stringify(Engine.get_copyright_info(), "  ") + "\n\n"
	var licenses := Engine.get_license_info()
	for name_value in licenses:
		notices += "## " + str(name_value) + "\n\n" + str(licenses[name_value]) + "\n\n"
	var file := FileAccess.open("res://../packaging/THIRD_PARTY_NOTICES.md", FileAccess.WRITE)
	if file == null:
		quit(1)
		return
	file.store_string(notices)
	file.close()
	quit(0)
