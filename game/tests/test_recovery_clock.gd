extends RefCounted

class FakeClock extends DuelClock:
	var mono: int = 1000000
	var wall: int = 1000000
	func monotonic_us() -> int: return mono
	func utc_ms() -> int: return wall
	func is_uncertain() -> bool: return false

func test_deadline_never_extends(a: DuelAssertions) -> void:
	var fake := FakeClock.new()
	var coordinator := RecoveryCoordinator.new()
	coordinator.clock = fake
	coordinator.observation = {"start_mono_us": 1000000, "remaining_ceiling_ms": 60000}
	fake.mono = 1000000 + 59999 * 1000
	a.equal(coordinator.remaining_ms(), 1, "59999ms remains one millisecond")
	fake.mono += 1000
	a.equal(coordinator.remaining_ms(), 0, "60000ms expired")
	fake.mono += 1000
	a.equal(coordinator.remaining_ms(), 0, "60001ms expired")
	coordinator.observation.remaining_ceiling_ms = 2000
	fake.mono = 1000000
	a.equal(coordinator.remaining_ms(), 2000, "persisted ceiling cannot increase")

func test_responsibility_matrix(a: DuelAssertions) -> void:
	a.equal(RecoveryCoordinator.identify_offender(true, false, 1), 0, "host restart")
	a.equal(RecoveryCoordinator.identify_offender(false, true, 0), 1, "guest restart")
	a.equal(RecoveryCoordinator.identify_offender(true, true, -1), -1, "both restart unresolved")
	a.equal(RecoveryCoordinator.identify_offender(false, false, 0), -1, "silence alone unresolved")
	a.equal(RecoveryCoordinator.identify_offender(false, false, 1, 0), 0, "authenticated leave")
