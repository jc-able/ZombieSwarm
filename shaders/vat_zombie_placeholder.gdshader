shader_type spatial;
render_mode cull_back;

// Placeholder animation shader for testing MultiMesh pipeline
// without real VAT textures. Creates a bobbing/swaying crowd effect.
// Colors change based on zombie state passed via INSTANCE_CUSTOM.y:
//   0 = running (red), 1 = climbing (yellow), 2 = falling (blue),
//   3 = start_climb (orange), 4 = standing_up (pink)
//
// NOTE: INSTANCE_CUSTOM is only available in vertex(), so we pass
// the state to fragment() via a varying.

uniform vec4 color_running     : source_color = vec4(1.0, 0.1, 0.1, 1.0);
uniform vec4 color_climbing    : source_color = vec4(1.0, 0.9, 0.1, 1.0);
uniform vec4 color_falling     : source_color = vec4(0.2, 0.4, 1.0, 1.0);
uniform vec4 color_start_climb : source_color = vec4(1.0, 0.5, 0.0, 1.0);
uniform vec4 color_standing_up : source_color = vec4(1.0, 0.2, 0.6, 1.0);

varying float v_state;

void vertex() {
	// Per-instance time offset from custom_data.x
	float time_offset = INSTANCE_CUSTOM.x;
	float state = INSTANCE_CUSTOM.y;
	float t = TIME * 8.0 + time_offset * 6.2831;

	// Pass state to fragment shader
	v_state = state;

	// Animation scale per state
	float anim_scale = 1.0;
	if (state > 0.5 && state < 1.5) anim_scale = 0.3;   // climbing
	if (state > 1.5 && state < 2.5) anim_scale = 0.0;    // falling
	if (state > 2.5 && state < 3.5) anim_scale = 0.1;    // start_climb
	if (state > 3.5) anim_scale = 0.2;                    // standing_up

	// Vertical bob (simulates running bounce)
	VERTEX.y += sin(t) * 0.12 * anim_scale;

	// Slight forward lean while "running"
	float lean = sin(t * 0.5) * 0.04 * anim_scale;
	VERTEX.z += VERTEX.y * lean;

	// Arm/leg sway (lateral wobble based on height)
	VERTEX.x += sin(t + VERTEX.y * 2.0) * 0.05 * anim_scale;
}

void fragment() {
	vec3 color = color_running.rgb;
	if (v_state > 0.5 && v_state < 1.5) color = color_climbing.rgb;
	if (v_state > 1.5 && v_state < 2.5) color = color_falling.rgb;
	if (v_state > 2.5 && v_state < 3.5) color = color_start_climb.rgb;
	if (v_state > 3.5) color = color_standing_up.rgb;
	ALBEDO = color;
}
