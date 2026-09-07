extends Node

var context: AppContext

func _ready() -> void:
	context = AppContext.new()
	add_child(context)
	context.start()
