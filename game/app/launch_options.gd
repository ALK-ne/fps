class_name LaunchOptions
extends RefCounted

var profile: String = "default"
var role: String = ""
var endpoint: String = "127.0.0.1:27840"
var scenario: String = ""
var seed_value: int = 20260906
var instance_lock_port: int = 27830
var test_fault: String = ""
var test_invite_file: String = ""

func parse(args: PackedStringArray) -> DuelResult:
	var mapping := {"profile": "profile", "role": "role", "endpoint": "endpoint", "scenario": "scenario", "seed": "seed_value", "instance-lock-port": "instance_lock_port", "test-fault": "test_fault", "test-invite-file": "test_invite_file"}
	var i := 0
	while i < args.size():
		var key := args[i].trim_prefix("--")
		if not mapping.has(key) or i + 1 >= args.size(): return DuelResult.failure("INVALID_ARGUMENT")
		if key in ["scenario", "seed", "test-fault", "test-invite-file"] and not OS.is_debug_build(): return DuelResult.failure("DEBUG_ARGUMENT_REJECTED")
		var value := args[i + 1]
		if key in ["seed", "instance-lock-port"]:
			if not value.is_valid_int(): return DuelResult.failure("INVALID_ARGUMENT")
			set(mapping[key], int(value))
		else: set(mapping[key], value)
		i += 2
	var regex := RegEx.new()
	regex.compile("^[a-zA-Z0-9_-]{1,32}$")
	if regex.search(profile) == null or role not in ["", "host", "guest", "practice"]: return DuelResult.failure("INVALID_ARGUMENT")
	return DuelResult.success(self)
