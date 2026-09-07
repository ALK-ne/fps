extends RefCounted

func test_remote_timeline(a: DuelAssertions) -> void:
	var buffer := RemoteInterpolation.new()
	a.truth(buffer.sample(0).is_empty(), "no invented remote state")
	for tick in [0, 3, 6, 9, 12]: buffer.push(tick, Vector3(tick, 0, 0), Vector3(60, 0, 0), 0, 1000)
	a.equal(buffer.sample(1000).position, Vector3(6, 0, 0), "100 ms behind latest snapshot")
	a.equal(buffer.sample(1025).position, Vector3(7.5, 0, 0), "interpolated between 20 Hz snapshots")
	a.equal(buffer.sample(1150).position, Vector3(15, 0, 0), "short dropout extrapolated")
	a.equal(buffer.sample(5000).position, Vector3(18, 0, 0), "long dropout freezes after 100 ms extrapolation")
	buffer.push(9, Vector3(999, 0, 0), Vector3.ZERO, 0, 5000)
	a.equal(buffer.sample(5000).position, Vector3(18, 0, 0), "old packet cannot rewind clock")
	buffer.clear()
	a.truth(buffer.sample(5000).is_empty(), "round or recovery clears old samples")
