#[compute]
#version 460

#include "utility.glsl"
#include "voxel_world.glsl"

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
    // Clipping
    float clip_near;
    float clip_far;
    float clip_sphere_radius;   // 0 = disabled
    float clip_sphere_mode;     // 0=hide outside sphere, 1=hide inside sphere

    vec4 clip_sphere_center;    // xyz = world position from bridge

    vec4 slice_plane;           // xyz=normal, w=offset; zero normal = disabled

    // Visualization
    float viz_mode;             // 0=normal, 1=normals, 2=depth, 3=step heatmap,
                                // 4=voxel type, 5=AO only, 6=shadow only, 7=brick grid
    float backface_mode;        // 0=off, 1=show backfaces, 2=backfaces only
    float ao_intensity;
    float shadow_intensity;

    // X-ray
    float xray_alpha;           // 0=opaque, >0=blend through layers
    float xray_max_layers;
    float edge_highlight;       // 0=off, >0=wireframe overlay strength
    float _pad3;

    vec4 _reserved;
} debug;

// ----------------------------------- OUTPUT -----------------------------------

layout(set = 2, binding = 0, rgba16f) restrict uniform writeonly image2D outputImage;

// ----------------------------------- FUNCTIONS -----------------------------------

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

// Heatmap: blue -> cyan -> green -> yellow -> red
vec3 heatmap(float t) {
    t = clamp(t, 0.0, 1.0);
    vec3 c;
    if (t < 0.25)      c = mix(vec3(0,0,1), vec3(0,1,1), t * 4.0);
    else if (t < 0.5)  c = mix(vec3(0,1,1), vec3(0,1,0), (t - 0.25) * 4.0);
    else if (t < 0.75) c = mix(vec3(0,1,0), vec3(1,1,0), (t - 0.5) * 4.0);
    else                c = mix(vec3(1,1,0), vec3(1,0,0), (t - 0.75) * 4.0);
    return c;
}

// Voxel type to distinct color
vec3 typeColor(Voxel voxel) {
    uint vtype = (voxel.data >> 24) & 0xFFu;
    if (vtype == VOXEL_TYPE_SOLID) return vec3(0.7, 0.7, 0.7);
    if (vtype == VOXEL_TYPE_WATER) return vec3(0.1, 0.3, 0.9);
    if (vtype == VOXEL_TYPE_LAVA)  return vec3(1.0, 0.3, 0.05);
    if (vtype == VOXEL_TYPE_SAND)  return vec3(0.9, 0.8, 0.4);
    if (vtype == VOXEL_TYPE_VINE)  return vec3(0.1, 0.7, 0.2);
    return vec3(1.0, 0.0, 1.0); // unknown
}

// Edge detection: how close is the hit point to a voxel edge
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

// Check if a hit point should be clipped by the sphere
bool sphereClipped(vec3 worldPos) {
    if (debug.clip_sphere_radius <= 0.0) return false;
    float dist = length(worldPos - debug.clip_sphere_center.xyz);
    if (debug.clip_sphere_mode < 0.5) {
        return dist > debug.clip_sphere_radius;
    } else {
        return dist < debug.clip_sphere_radius;
    }
}

// Check if a hit point should be clipped by the slice plane
bool slicePlaneClipped(vec3 worldPos) {
    vec3 n = debug.slice_plane.xyz;
    if (dot(n, n) < 0.001) return false;
    return dot(worldPos, normalize(n)) > debug.slice_plane.w;
}

// Shade a voxel hit according to the current viz mode
vec3 shadeVoxel(Voxel voxel, vec3 hitPos, ivec3 grid_position, vec3 normal, int step_count, vec3 ray_dir) {
    int mode = int(debug.viz_mode + 0.5);
    vec3 voxel_pos = vec3(grid_position) * voxelWorldProperties.scale;
    vec3 voxel_view_dir = normalize(cameraParams.position.xyz - voxel_pos);

    if (mode == 1) return normal * 0.5 + 0.5;
    if (mode == 2) return vec3(1.0 - clamp(length(hitPos - cameraParams.position.xyz) / debug.clip_far, 0.0, 1.0));
    if (mode == 3) return heatmap(float(step_count) / 200.0);
    if (mode == 4) return typeColor(voxel);
    if (mode == 5) return vec3(computeAmbientOcclusion(hitPos, grid_position, normal));
    if (mode == 6) return vec3(computeShadow(hitPos, normal, voxelWorldProperties.sun_direction.xyz));

    if (mode == 7) {
        vec3 baseColor = getVoxelColor(voxel, grid_position);
        ivec3 localInBrick = grid_position % BRICK_EDGE_LENGTH;
        bool onBrickEdge = any(equal(localInBrick, ivec3(0))) || any(equal(localInBrick, ivec3(BRICK_EDGE_LENGTH - 1)));
        if (onBrickEdge) baseColor = mix(baseColor, vec3(1.0, 0.2, 0.2), 0.5);
        return baseColor;
    }

    // Mode 0: Normal rendering with debug overrides
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
        color = ao * blinnPhongShading(color, normal, normalize(voxelWorldProperties.sun_direction.xyz), voxelWorldProperties.sun_color.rgb, voxel_view_dir, shadow);
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

    // Use plain variables for voxelTraceWorld out params (not struct members)
    ivec3 grid_position;
    vec3 normal;
    int step_count = 0;
    float t;
    Voxel voxel;
    vec3 color = vec3(0.0);

    float range_near = debug.clip_near;
    float range_far = debug.clip_far;

    if (voxelTraceWorld(ray_origin, ray_dir, vec2(range_near, range_far), voxel, t, grid_position, normal, step_count)) {
        vec3 hitPos = ray_origin + t * ray_dir;
        normal = normalize(normal);

        // Apply clipping — if clipped, show sky
        if (sphereClipped(hitPos) || slicePlaneClipped(hitPos)) {
            color = sampleSkyColor(ray_dir);
        } else {
            color = shadeVoxel(voxel, hitPos, grid_position, normal, step_count, ray_dir);
        }
    } else {
        color = sampleSkyColor(ray_dir);
    }

    imageStore(outputImage, pos, vec4(color, 1.0));
}
