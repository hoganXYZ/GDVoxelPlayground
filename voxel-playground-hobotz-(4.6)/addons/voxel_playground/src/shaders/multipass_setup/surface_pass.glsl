#[compute]
#version 460

#include "../utility.glsl"
#include "../voxel_world.glsl"

// ----------------------------------- CAMERA + RENDER PARAMS -----------------------------------

layout(std430, set = 1, binding = 0) restrict buffer CameraParams {
    mat4 view_projection;
    mat4 inv_view_projection;
    vec4 position;
    uint frame_index;
    float near_plane;
    float far_plane;
    float _pad0;
    int width;
    int height;
    float _pad1;
    float _pad2;
} cameraParams;

// ----------------------------------- DEBUG PARAMS (push constants) -----------------------------------

layout(push_constant) uniform DebugParams {
    float clip_near;
    float clip_far;
    float clip_sphere_radius;
    float clip_sphere_mode;
    vec4 clip_sphere_center;
    vec4 slice_plane;
    float viz_mode;
    float backface_mode;
    float ao_intensity;
    float shadow_intensity;
    float xray_alpha;
    float xray_max_layers;
    float edge_highlight;
    float _pad3;
    vec4 _reserved;
} debug;

// ----------------------------------- OUTPUT -----------------------------------

layout(set = 2, binding = 0, rgba16f) restrict uniform writeonly image2D surfaceColor;
layout(set = 2, binding = 1, r32f)    restrict uniform writeonly image2D surfaceDepth;

// ----------------------------------- SHADING -----------------------------------

vec3 blinnPhongShading(vec3 baseColor, vec3 normal, vec3 lightDir, vec3 lightColor, vec3 viewDir, float shadow) {
    float NdotL = max(dot(normal, lightDir), 0.0);
    vec3 diffuse = NdotL * baseColor;

    vec3 H = normalize(lightDir + viewDir);
    float NdotH = max(dot(normal, H), 0.0);
    vec3 specular = pow(NdotH, 10.0) * lightColor;

    vec3 ambient = baseColor;

    vec3 result = 0.25 * shadow * specular;
    result += (shadow * 0.5 + 0.5) * diffuse;
    result += 0.2 * ambient;
    return result;
}

float voxelEdgeFactor(vec3 hitPos, vec3 normal, float scale) {
    vec3 gridPos = hitPos / scale;
    vec3 f = fract(gridPos);
    vec3 an = abs(normal);
    vec2 uv;
    if (an.x > 0.5)      uv = f.yz;
    else if (an.y > 0.5)  uv = f.xz;
    else                   uv = f.xy;
    float edge = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
    return 1.0 - smoothstep(0.0, 0.08, edge);
}

vec3 shadeVoxelSurface(Voxel voxel, vec3 hitPos, ivec3 grid_position, vec3 normal, int step_count, vec3 ray_dir) {
    vec3 voxel_pos = vec3(grid_position) * voxelWorldProperties.scale;
    vec3 voxel_view_dir = normalize(cameraParams.position.xyz - voxel_pos);

    float emission = getVoxelEmission(voxel);
    vec3 color = getVoxelColor(voxel, grid_position) * (1.0 + emission);

    if (isVoxelLiquid(voxel)) {
        color += vec3(0.05 * sin(0.0167 * voxelWorldProperties.frame + 0.2 * (grid_position.x + grid_position.y + grid_position.z)));
        color += vec3(((voxel.data & 0xFu) > 0) ? 0.5 : 0);
    }

    if (emission < 1.0) {
        float shadow = computeShadow(hitPos, normal, voxelWorldProperties.sun_direction.xyz) * debug.shadow_intensity;
        float ao = computeAmbientOcclusion(hitPos, grid_position, normal);
        ao = mix(1.0, ao, debug.ao_intensity) * 0.7 + 0.3;
        color = ao * blinnPhongShading(color, normal, normalize(voxelWorldProperties.sun_direction.xyz),
            voxelWorldProperties.sun_color.rgb, voxel_view_dir, shadow);
    }

    if (debug.edge_highlight > 0.0) {
        float ef = voxelEdgeFactor(hitPos, normal, voxelWorldProperties.scale);
        color = mix(color, vec3(1.0), ef * debug.edge_highlight);
    }

    return color;
}

// ----------------------------------- MAIN -----------------------------------

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;
void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    if (pos.x >= cameraParams.width || pos.y >= cameraParams.height) return;

    vec2 screen_uv = vec2(pos + 0.5) / vec2(cameraParams.width, cameraParams.height);
    vec4 ndc = vec4(screen_uv * 2.0 - 1.0, 0.0, 1.0);
    vec4 world_pos = cameraParams.inv_view_projection * ndc;
    world_pos /= world_pos.w;
    vec3 ray_origin = cameraParams.position.xyz;
    vec3 ray_dir = normalize(world_pos.xyz - ray_origin);

    float range_near = debug.clip_near;
    float range_far  = debug.clip_far;

    Voxel voxel; float t; ivec3 grid_position; vec3 normal; int step_count;
    bool hit = voxelTraceWorld(ray_origin, ray_dir, vec2(range_near, range_far),
        voxel, t, grid_position, normal, step_count);

    if (hit) {
        vec3 hitPos = ray_origin + t * ray_dir;
        normal = normalize(normal);
        vec3 color = shadeVoxelSurface(voxel, hitPos, grid_position, normal, step_count, ray_dir);
        imageStore(surfaceColor, pos, vec4(color, 1.0));
        imageStore(surfaceDepth, pos, vec4(t));
    } else {
        vec3 sky = sampleSkyColor(ray_dir);
        imageStore(surfaceColor, pos, vec4(sky, 0.0)); // alpha 0 = sky (no geometry)
        imageStore(surfaceDepth, pos, vec4(range_far));
    }
}
