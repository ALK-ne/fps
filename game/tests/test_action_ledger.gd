extends RefCounted

func test_duplicate_pending_completion_and_eviction(a: DuelAssertions) -> void:
	var ledger := ActionLedger.new()
	ledger.reset(1)
	a.truth(ledger.begin(1, 1, 100, 7).execute, "new action executes")
	a.equal(ledger.begin(1, 1, 101, 7), {"execute": false, "pending": true}, "held swap duplicate has no second effect or early result")
	var result := ledger.complete(1, 0, 8, 160)
	a.equal(result.value, {"round": 1, "actionId": 1, "resultCode": 0, "inventoryRevision": 8, "acceptedTick": 100, "completeTick": 160}, "result keeps distinct accepted/completed ticks")
	a.equal(ledger.begin(1, 1, 200, 99).result, result.value, "completed duplicate returns original result")
	a.equal(ledger.complete(1, 8, 99, 200).value, result.value, "duplicate completion cannot overwrite success")
	result.value.resultCode = 8
	a.equal(ledger.begin(1, 1, 201, 99).result.resultCode, 0, "caller cannot mutate stored result")
	for id in range(2, 2051):
		ledger.begin(1, id, id + 200, 8)
		ledger.complete(id, 0, 8, id + 200)
	a.equal(ledger.results.size(), 2048, "result cache bounded")
	a.equal(ledger.begin(1, 1, 3000, 8).result.resultCode, 12, "evicted request rejected by highwater")
	a.equal(ledger.begin(2, 2051, 3000, 8).result.resultCode, 2, "future round refused")
	ledger.reset(2)
	a.truth(ledger.begin(2, 1, 4000, 0).execute, "new round can reuse action IDs")
	a.equal(ledger.begin(1, 2051, 4000, 0).result.resultCode, 2, "old round request cannot enter new round")

func test_pending_limit(a: DuelAssertions) -> void:
	var ledger := ActionLedger.new()
	ledger.reset(1)
	for id in range(1, 17): a.truth(ledger.begin(1, id, 100, 0).execute, "pending action accepted within cap")
	a.equal(ledger.begin(1, 17, 100, 0).result.resultCode, 8, "excess pending request refused")
	a.equal(ledger.pending.size(), 16, "pending allocation bounded")
	ledger.complete(1, 8, 0, 110)
	a.equal(ledger.begin(1, 17, 120, 0).result.resultCode, 8, "rejected ID cannot execute on retry")
	a.truth(ledger.begin(1, 18, 120, 0).execute, "new request after a cancellation accepted")
