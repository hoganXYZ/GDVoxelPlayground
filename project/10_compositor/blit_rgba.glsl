#[compute]
#version 450

// Simple RGBA blit/copy compute shader.
// Copies input_image to output_image with no modification.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D input_image;
layout(rgba16f, set = 1, binding = 0) uniform restrict writeonly image2D output_image;

layout(push_constant, std430) uniform Params {
	vec2 size;
	vec2 reserved;
} params;

void main() {
	ivec2 size = ivec2(params.size);
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);

	if (uv.x >= size.x || uv.y >= size.y) {
		return;
	}

	vec4 color = imageLoad(input_image, uv);
	imageStore(output_image, uv, color);
}
