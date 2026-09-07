class_name HealingSystem
extends RefCounted

var config: GameConfig

func begin(player: PlayerState, kind: int, tick: int) -> DuelResult:
	if kind < 1 or kind > 4 or player.inventory.heals[kind - 1] < 1: return DuelResult.failure("NO_STOCK")
	if player.movement.sprinting or player.movement.vaulting: return DuelResult.failure("ACTION_CONFLICT")
	var definition := config.heal(kind)
	if (definition.target == "hp" and player.hp_milli >= 100000) or (definition.target == "armor" and player.armor_milli >= player.armor_max): return DuelResult.failure("CAP_REACHED")
	player.action = CanonicalCodec.Action.HEAL
	player.action_kind = kind
	player.action_end_tick = tick + config.ticks(definition.useMs)
	return DuelResult.success()

func complete(player: PlayerState, tick: int) -> bool:
	if player.action != CanonicalCodec.Action.HEAL or tick < player.action_end_tick: return false
	if player.hp_milli <= 0:
		player.action = CanonicalCodec.Action.IDLE
		return false
	var definition := config.heal(player.action_kind)
	if player.inventory.heals[player.action_kind - 1] < 1: return false
	if definition.target == "hp": player.hp_milli = 100000 if definition.full else mini(100000, player.hp_milli + int(definition.amount) * 1000)
	else: player.armor_milli = player.armor_max if definition.full else mini(player.armor_max, player.armor_milli + int(definition.amount) * 1000)
	player.inventory.heals[player.action_kind - 1] -= 1
	player.inventory.revision += 1
	player.action = CanonicalCodec.Action.IDLE
	return true
