shader_type spatial;

uniform sampler2D screen;

void vertex() {
	// Called for every vertex the material is visible on.
}

void fragment() {
	vec4 img = texture(screen, UV);
	
	ALBEDO = img.xyz;
}

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
