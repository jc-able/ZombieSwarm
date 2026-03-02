shader_type spatial;
render_mode cull_back;

// VAT textures (baked from Blender)
uniform sampler2D vat_position : hint_default_black, filter_nearest, repeat_disable;
uniform sampler2D vat_normal : hint_default_black, filter_nearest, repeat_disable;

// Albedo texture from original zombie
uniform sampler2D albedo_tex : source_color;

// Animation parameters
uniform float num_frames = 30.0;
uniform float fps = 30.0;
uniform int num_vertices = 1;

void vertex() {
	// Per-instance animation time offset (from custom_data.x)
	float time_offset = INSTANCE_CUSTOM.x;

	// Current animation frame (loops)
	float current_time = TIME + time_offset;
	float frame = mod(current_time * fps, num_frames);
	float frame_normalized = frame / num_frames;

	// Vertex index -> X coordinate in VAT texture
	float vertex_u = (float(VERTEX_ID) + 0.5) / float(num_vertices);

	// Sample position from VAT
	vec2 vat_uv = vec2(vertex_u, frame_normalized);
	vec3 new_position = texture(vat_position, vat_uv).rgb;

	// Sample normal from VAT (stored as 0-1 range, remap to -1..1)
	vec3 new_normal = texture(vat_normal, vat_uv).rgb * 2.0 - 1.0;

	VERTEX = new_position;
	NORMAL = new_normal;
}

void fragment() {
	ALBEDO = texture(albedo_tex, UV).rgb;
}
