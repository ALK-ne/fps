shader_type spatial;
render_mode diffuse_lambert, specular_disabled;
uniform vec4 base_color : source_color = vec4(0.3, 0.4, 0.6, 1.0);
void fragment() {
	ALBEDO = base_color.rgb;
	ROUGHNESS = 1.0;
}
void light() {
	float n = dot(NORMAL, LIGHT);
	float band = n > 0.6 ? 1.0 : (n > 0.15 ? 0.65 : 0.3);
	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * band * ATTENUATION;
}
