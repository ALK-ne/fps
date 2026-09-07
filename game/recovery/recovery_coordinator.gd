class_name RecoveryCoordinator
extends RefCounted

var observation: Dictionary = {}
var clock: DuelClock
var store: RecoveryStore
var suspended: bool = false
var expired: bool = false
var conflict: bool = false
var last_persist_second: int = -1

func on_link_lost(cause: int, epoch: int = 1, own_boot: PackedByteArray = PackedByteArray(), peer_boot: PackedByteArray = PackedByteArray()) -> DuelResult:
	suspended = true
	if not observation.is_empty(): return DuelResult.success()
	observation = {"old_epoch": epoch, "round": store.state.round, "own_boot": own_boot, "peer_boot": peer_boot, "cause": cause,
		"start_mono_us": clock.monotonic_us(), "start_utc_ms": clock.utc_ms(), "remaining_ceiling_ms": 60000, "terminal": false}
	return store.persist_observation(observation)

func remaining_ms() -> int:
	if observation.is_empty(): return 0
	return maxi(0, mini(int(observation.remaining_ceiling_ms), 60000 - int((clock.monotonic_us() - int(observation.start_mono_us)) / 1000)))

func step(_monotonic_us: int, _utc_ms: int) -> Array:
	if not suspended or observation.is_empty(): return []
	if clock.is_uncertain():
		conflict = true
		return ["CLOCK_UNCERTAIN"]
	var remaining := remaining_ms()
	if remaining / 1000 != last_persist_second:
		last_persist_second = remaining / 1000
		observation.remaining_ceiling_ms = remaining
		var result := store.persist_observation(observation)
		if not result.ok: return ["STORE_WRITE_FAILED"]
	if remaining == 0 and not expired:
		expired = true
		observation.terminal = true
		var saved := store.persist_observation(observation)
		return ["RECOVERY_EXPIRED"] if saved.ok else ["STORE_WRITE_FAILED"]
	return []

static func identify_offender(host_changed: bool, guest_changed: bool, continuous_slot: int, graceful_slot: int = -1) -> int:
	if host_changed and not guest_changed and continuous_slot == 1: return 0
	if guest_changed and not host_changed and continuous_slot == 0: return 1
	if not host_changed and not guest_changed and graceful_slot in [0, 1]: return graceful_slot
	return -1

func can_enter_gameplay() -> bool:
	return not suspended and not expired and not conflict
