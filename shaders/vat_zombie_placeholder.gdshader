shader_type spatial;
render_mode cull_back;

// Placeholder animation shader for testing MultiMesh pipeline
// without real VAT textures. Creates a bobbing/swaying crowd effect.

uniform vec4 body_color : source_color = vec4(0.35, 0.55, 0.25, 1.0);

void vertex() {
	// Per-instance time offset from custom_data.x
	float time_offset = INSTANCE_CUSTOM.x;
	float t = TIME * 8.0 + time_offset * 6.2831;

	// Vertical bob (simulates running bounce)
	VERTEX.y += sin(t) * 0.12;

	// Slight forward lean while "running"
	float lean = sin(t * 0.5) * 0.04;
	VERTEX.z += VERTEX.y * lean;

	// Arm/leg sway (lateral wobble based on height)
	VERTEX.x += sin(t + VERTEX.y * 2.0) * 0.05;
}

void fragment() {
	ALBEDO = body_color.rgb;
}
