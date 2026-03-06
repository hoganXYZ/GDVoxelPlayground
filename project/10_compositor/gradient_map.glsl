#[compute]
#version 450

// Gradient map compute shader.
// Remaps pixel values to colors along a gradient based on luminance,
// brightness, value, lightness, or luma. Similar to Photoshop's gradient map.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D input_image;
layout(rgba16f, set = 1, binding = 0) uniform restrict writeonly image2D output_image;
layout(rgba16f, set = 2, binding = 0) uniform restrict readonly image2D gradient_image;

layout(push_constant, std430) uniform Params {
	vec2 size;
	float mode;           // 0=luminance, 1=brightness, 2=value, 3=lightness, 4=luma
	float blend;          // 0.0 = full gradient, 1.0 = original image
	float gradient_width; // Width of the gradient texture
	float reserved1;
	float reserved2;
	float reserved3;
} params;

// Rec. 709 luminance (perceptual, used in HDTV)
float get_luminance(vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

// Simple brightness (average of RGB)
float get_brightness(vec3 c) {
	return (c.r + c.g + c.b) / 3.0;
}

// HSV value (maximum of RGB)
float get_value(vec3 c) {
	return max(max(c.r, c.g), c.b);
}

// HSL lightness (average of min and max RGB)
float get_lightness(vec3 c) {
	float max_c = max(max(c.r, c.g), c.b);
	float min_c = min(min(c.r, c.g), c.b);
	return (max_c + min_c) * 0.5;
}

// Rec. 601 luma (used in SDTV, often called "perceptual brightness")
float get_luma(vec3 c) {
	return dot(c, vec3(0.299, 0.587, 0.114));
}

// Sample the gradient texture at position t (0.0 to 1.0)
vec3 sample_gradient(float t) {
	t = clamp(t, 0.0, 1.0);
	int x = int(t * (params.gradient_width - 1.0));
	return imageLoad(gradient_image, ivec2(x, 0)).rgb;
}

void main() {
	ivec2 size = ivec2(params.size);
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);

	if (uv.x >= size.x || uv.y >= size.y) {
		return;
	}

	vec4 color = imageLoad(input_image, uv);

	// Get the mapping value based on selected mode
	float t;
	int mode = int(params.mode);

	if (mode == 0) {
		t = get_luminance(color.rgb);
	} else if (mode == 1) {
		t = get_brightness(color.rgb);
	} else if (mode == 2) {
		t = get_value(color.rgb);
	} else if (mode == 3) {
		t = get_lightness(color.rgb);
	} else {
		t = get_luma(color.rgb);
	}

	// Sample the gradient
	vec3 mapped = sample_gradient(t);

	// Blend between gradient-mapped and original based on blend parameter
	vec3 result = mix(mapped, color.rgb, params.blend);

	imageStore(output_image, uv, vec4(result, color.a));
}
