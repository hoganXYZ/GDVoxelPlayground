#[compute]
#version 460

#include "../utility.glsl.inc"
#include "../voxel_world.glsl.inc"
#include "../voxel_elements.glsl.inc"

// Projects a 2D texture into the voxel world: one thread per texel casts a ray
// through the projector frustum and converts the first voxel it hits into the
// requested element, colored by the texel. Texels below the alpha threshold
// project nothing, so text/sprites on a transparent background keep their shape.

layout(std430, set = 1, binding = 0) restrict buffer Params {
    mat4 inv_view_projection; // perspective mode only
    vec4 origin;          // xyz = projector position (perspective apex / parallel view-plane center)
    vec4 right_extent;    // parallel mode: view-plane half-extent along screen right (world units)
    vec4 up_extent;       // parallel mode: view-plane half-extent along screen up (world units)
    vec4 direction;       // parallel mode: shared ray direction (e.g. oblique sheared forward)
    vec4 tint;            // rgb multiplied into the sampled color
    int tex_width;
    int tex_height;
    float alpha_threshold;
    float max_range;
    uint value;           // same encoding as sphere_edit: legacy index or (type<<24)|(1<<16)|color16
    uint place_on_surface; // 0 = convert the hit voxel, 1 = fill the air voxel in front of it
    uint ray_mode;        // 0 = perspective frustum, 1 = parallel rays (ortho/oblique, matches voxel_renderer_oblique)
    uint _pad0;
} params;

layout(set = 1, binding = 1) uniform sampler2D projector_texture;

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;
void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    if (pixel.x >= params.tex_width || pixel.y >= params.tex_height) return;

    vec4 texel = texelFetch(projector_texture, pixel, 0);
    if (texel.a < params.alpha_threshold) return;

    // NDC y is flipped so texture row 0 (top) lands at the top of the view,
    // matching both voxel_renderer.glsl and voxel_renderer_oblique.glsl.
    vec2 uv = (vec2(pixel) + 0.5) / vec2(params.tex_width, params.tex_height);
    vec2 ndc_xy = uv * 2.0 - 1.0;
    ndc_xy.y = -ndc_xy.y;

    vec3 ray_origin;
    vec3 ray_dir;
    if (params.ray_mode == 1u) {
        // Parallel rays: origins spread across the view plane, one shared
        // direction — same construction as the oblique renderer / mouse editor.
        ray_origin = params.origin.xyz
                   + params.right_extent.xyz * ndc_xy.x
                   + params.up_extent.xyz * ndc_xy.y;
        ray_dir = normalize(params.direction.xyz);
    } else {
        // Perspective frustum: unproject through the inverse view-projection.
        vec4 world_pos = params.inv_view_projection * vec4(ndc_xy, 0.0, 1.0);
        world_pos /= world_pos.w;
        ray_origin = params.origin.xyz;
        ray_dir = normalize(world_pos.xyz - ray_origin);
    }

    Voxel hit_voxel;
    float t;
    ivec3 grid_position;
    vec3 normal;
    int step_count;
    if (!voxelTraceWorld(ray_origin, ray_dir, vec2(0.0, params.max_range), hit_voxel, t, grid_position, normal, step_count))
        return;
    if (isVoxelEntity(hit_voxel))
        return;

    ivec3 write_pos = grid_position;
    if (params.place_on_surface != 0u) {
        write_pos = grid_position + ivec3(normal);
        if (!isValidPos(write_pos)) return;
        // Emitter mode only fills empty cells so it never eats the surface.
        if (!isVoxelAir(getVoxel(posToIndex(write_pos)))) return;
    }

    // Decode the element type (same scheme as sphere_edit.glsl); the texel
    // provides the color, so the custom encoding's color16 bits are ignored.
    uint voxel_type = VOXEL_TYPE_AIR;
    if ((params.value & (1u << 16u)) != 0u) {
        voxel_type = (params.value >> 24u) & 0xFFu;
    } else {
        if (params.value == 1u) voxel_type = VOXEL_TYPE_SOLID;
        if (params.value == 2u) voxel_type = VOXEL_TYPE_SAND;
        if (params.value == 3u) voxel_type = VOXEL_TYPE_WATER;
        if (params.value == 4u) voxel_type = VOXEL_TYPE_LAVA;
        if (params.value == 5u) voxel_type = VOXEL_TYPE_VINE;
    }

    Voxel new_voxel;
    if (voxel_type == VOXEL_TYPE_AIR) {
        if (params.place_on_surface != 0u) return; // erasing air is a no-op
        new_voxel = createAirVoxel();
    } else {
        new_voxel = createVoxel(voxel_type, texel.rgb * params.tint.rgb);
        if (voxel_type == VOXEL_TYPE_VINE)
            new_voxel.data |= 15u; // energy
    }

    uint index = posToIndex(write_pos);
    setBothVoxelBuffers(index, new_voxel);
    setBothAux(index, defaultAuxFor(voxel_type));
}
