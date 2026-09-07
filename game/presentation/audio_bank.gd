class_name AudioBank
extends RefCounted

var sounds: Dictionary = {}

func build() -> void:
	for kind in ["rifle", "shotgun", "pistol", "step", "hit", "armor", "pickup", "explosion"]:
		var path: String = "res://presentation/audio/" + kind + ".wav"
		if ResourceLoader.exists(path):
			sounds[kind] = load(path)
			continue
		var duration: float = {"rifle": 0.07, "shotgun": 0.16, "pistol": 0.09, "step": 0.08, "hit": 0.05, "armor": 0.14, "pickup": 0.1, "explosion": 0.3}[kind]
		var rng := RandomNumberGenerator.new()
		rng.seed = 20260906 + kind.hash()
		var data := PackedByteArray()
		var count := int(duration * 48000)
		data.resize(count * 2)
		var low := 0.0
		for i in count:
			var time := i / 48000.0
			var envelope := pow(1.0 - i / float(count), 2)
			var noise := rng.randf_range(-1, 1)
			low = lerpf(low, noise, 0.13)
			var value := noise * 0.4 + sin(time * TAU * 120) * 0.3
			match kind:
				"shotgun", "step", "explosion": value = low * 1.8
				"pistol": value = noise * 0.4 + sin(time * TAU * 220) * 0.3
				"hit": value = sin(TAU * (1000 * time - 400 / duration * time * time * 0.5)) * 0.5
				"armor": value = (sin(time * TAU * 800) + sin(time * TAU * 1200) + sin(time * TAU * 1600)) / 6
				"pickup": value = sin(time * TAU * 660) * 0.4
			data.encode_s16(i * 2, int(clampf(value * envelope, -1, 1) * 32767))
		var stream := AudioStreamWAV.new()
		stream.format = AudioStreamWAV.FORMAT_16_BITS
		stream.mix_rate = 48000
		stream.stereo = false
		stream.data = data
		sounds[kind] = stream
