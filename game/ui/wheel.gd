class_name DuelWheel
extends Control

var labels: Array = []
var counts: Array = []
var selected: int = 1

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func configure(names: Array, stock: Array, choice: int) -> void:
	labels = names
	counts = stock
	selected = choice
	queue_redraw()

func _draw() -> void:
	if labels.is_empty(): return
	var center := size / 2
	var font := get_theme_default_font()
	var count := labels.size()
	for i in count:
		var start := i * TAU / count - PI / 4
		var finish := (i + 1) * TAU / count - PI / 4
		var polygon := PackedVector2Array([center])
		for step in 25: polygon.append(center + Vector2.from_angle(lerpf(start, finish, step / 24.0)) * 230)
		var chosen := i + 1 == selected
		draw_colored_polygon(polygon, Color(0.1, 0.45, 0.6, 0.94) if chosen else Color(0.04, 0.07, 0.12, 0.94))
		draw_arc(center, 230, start, finish, 24, Color("41d9ff") if chosen else Color("465875"), 3, true)
		var at := center + Vector2.from_angle((start + finish) / 2) * 145
		var color := Color.WHITE if counts[i] > 0 else Color("7b8798")
		var text := str(labels[i]) + " ×" + str(counts[i])
		var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x
		draw_string(font, at + Vector2(-width / 2, 8), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, color)
	draw_circle(center, 65, Color("111827"))
	draw_string(font, center + Vector2(-44, 8), "選択中", HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color.WHITE)
