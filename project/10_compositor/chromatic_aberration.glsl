#[compute]
#version 450

// Chromatic aberration compute shader.
// Splits R, G, B channels by sampling at radially offset positions.
// The offset magnitude increases with distance from the center point,
// controlled by intensity and falloff parameters.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D input_image;
layout(rgba16f, set = 1, binding = 0) uniform restrict writeonly image2D output_image;

layout(push_constant, std430) uniform Params {
	vec2 size;
	vec2 center;
	float intensity;
	float falloff;
	float reserved1;
	float reserved2;
} params;

void main() {
	ivec2 size = ivec2(params.size);
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);

	if (uv.x >= size.x || uv.y >= size.y) {
		return;
	}

	// Compute radial direction and distance from center
	vec2 dir = vec2(uv) - params.center;
	float max_dist = length(params.size * 0.5);
	float dist = length(dir) / max_dist;
	float mask = pow(clamp(dist, 0.0, 1.0), params.falloff);

	// Offset along the radial direction, scaled by distance falloff
	vec2 offset = normalize(dir + vec2(0.001)) * params.intensity * mask;

	// Sample each channel at a different radial offset:
	//   Red   - shifted outward from center
	//   Green - no shift (anchor channel)
	//   Blue  - shifted inward toward center
	ivec2 uv_r = ivec2(clamp(vec2(uv) + offset, vec2(0.0), vec2(size) - 1.0));
	ivec2 uv_b = ivec2(clamp(vec2(uv) - offset, vec2(0.0), vec2(size) - 1.0));

	float r = imageLoad(input_image, uv_r).r;
	vec4 center_color = imageLoad(input_image, uv);
	float b = imageLoad(input_image, uv_b).b;

	imageStore(output_image, uv, vec4(r, center_color.g, b, center_color.a));
}
