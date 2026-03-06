#[compute]
#version 450

// Color halftone compute shader.
// Simulates CMYK halftone printing by converting the image to CMYK,
// then rendering each channel as a grid of circular dots rotated at
// traditional screen angles. Dot size is proportional to channel
// intensity, producing the classic printed-page look.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D input_image;
layout(rgba16f, set = 1, binding = 0) uniform restrict writeonly image2D output_image;

layout(push_constant, std430) uniform Params {
	vec2 size;
	float dot_size;
	float softness;
	float angle_c;
	float angle_m;
	float angle_y;
	float angle_k;
	float blend_mode;
	float strength;
	float reserved1;
	float reserved2;
} params;

// Blend modes: 0 = Normal, 1 = Multiply, 2 = Screen, 3 = Overlay, 4 = Soft Light
vec3 blend(vec3 base, vec3 halftone) {
	int mode = int(params.blend_mode);
	vec3 result;

	if (mode == 1) {
		// Multiply
		result = base * halftone;
	} else if (mode == 2) {
		// Screen
		result = 1.0 - (1.0 - base) * (1.0 - halftone);
	} else if (mode == 3) {
		// Overlay: Multiply darks, Screen lights
		result = mix(
			2.0 * base * halftone,
			1.0 - 2.0 * (1.0 - base) * (1.0 - halftone),
			step(0.5, base)
		);
	} else if (mode == 4) {
		// Soft Light (Pegtop formula)
		result = (1.0 - 2.0 * halftone) * base * base + 2.0 * halftone * base;
	} else {
		// Normal (replace)
		result = halftone;
	}

	return mix(base, result, params.strength);
}

// Returns the halftone dot coverage for a single channel.
// `value` is the ink amount (0 = no ink, 1 = full ink).
float halftone(vec2 uv, float angle, float value) {
	float s = sin(angle);
	float c = cos(angle);
	mat2 rot = mat2(c, -s, s, c);

	vec2 rotated = rot * uv;
	vec2 cell = (floor(rotated / params.dot_size + 0.5)) * params.dot_size;
	float dist = length(rotated - cell);

	// sqrt gives perceptually linear dot area scaling
	float radius = params.dot_size * 0.5 * sqrt(clamp(value, 0.0, 1.0));
	float edge = params.dot_size * params.softness * 0.5;
	return smoothstep(radius + edge, radius - edge, dist);
}

void main() {
	ivec2 size = ivec2(params.size);
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);

	if (uv.x >= size.x || uv.y >= size.y) {
		return;
	}

	vec4 color = imageLoad(input_image, uv);

	// RGB -> CMYK
	float k = 1.0 - max(color.r, max(color.g, color.b));
	float inv_k = 1.0 / max(1.0 - k, 0.001);
	float c_val = (1.0 - color.r - k) * inv_k;
	float m_val = (1.0 - color.g - k) * inv_k;
	float y_val = (1.0 - color.b - k) * inv_k;

	// Evaluate halftone dot for each channel at its screen angle
	vec2 pos = vec2(uv);
	float c_dot = halftone(pos, params.angle_c, c_val);
	float m_dot = halftone(pos, params.angle_m, m_val);
	float y_dot = halftone(pos, params.angle_y, y_val);
	float k_dot = halftone(pos, params.angle_k, k);

	// CMYK -> RGB
	vec3 result;
	result.r = (1.0 - c_dot) * (1.0 - k_dot);
	result.g = (1.0 - m_dot) * (1.0 - k_dot);
	result.b = (1.0 - y_dot) * (1.0 - k_dot);

	// Apply blend mode and strength
	result = blend(color.rgb, result);

	imageStore(output_image, uv, vec4(result, color.a));
}
