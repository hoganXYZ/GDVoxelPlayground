#[compute]
#version 450

// Film grain compute shader.
// Generates pseudo-random noise per pixel and blends it with the source
// image. The grain responds to luminance so darker areas pick up more
// noise, matching the behaviour of real photographic film.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D input_image;
layout(rgba16f, set = 1, binding = 0) uniform restrict writeonly image2D output_image;

layout(push_constant, std430) uniform Params {
	vec2 size;
	float seed;
	float intensity;
	float luminance_response;
	float grain_size;
	float reserved1;
	float reserved2;
} params;

// Fast hash – gives a [0, 1] pseudo-random value for a 2D coordinate.
float hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void main() {
	ivec2 size = ivec2(params.size);
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);

	if (uv.x >= size.x || uv.y >= size.y) {
		return;
	}

	vec4 color = imageLoad(input_image, uv);

	// Quantize UVs by grain_size so the noise has visible "clumps"
	vec2 grain_uv = floor(vec2(uv) / max(params.grain_size, 1.0));

	// Seed offsets the entire noise field each frame
	float noise = hash(grain_uv + params.seed * 1.337) * 2.0 - 1.0;

	// Luminance-dependent response: darker pixels receive more grain
	float luminance = dot(color.rgb, vec3(0.2126, 0.7152, 0.0722));
	float luma_factor = mix(1.0, 1.0 - clamp(luminance, 0.0, 1.0), params.luminance_response);

	vec3 result = color.rgb + vec3(noise) * params.intensity * luma_factor;

	imageStore(output_image, uv, vec4(result, color.a));
}
