class_name DuelClock
extends RefCounted

var anchor_mono: int = Time.get_ticks_usec()
var anchor_utc: int = int(Time.get_unix_time_from_system() * 1000.0)

func monotonic_us() -> int:
	return Time.get_ticks_usec()

func utc_ms() -> int:
	return int(Time.get_unix_time_from_system() * 1000.0)

func is_uncertain() -> bool:
	return abs((utc_ms() - anchor_utc) - (monotonic_us() - anchor_mono) / 1000) >= 2000
