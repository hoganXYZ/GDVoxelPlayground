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
// Tunnel color: rgb = shaded tunnel wall, a = 1.0 if tunnel hit, 0.0 if no tunnel
// Tunnel depth: world-space t of the tunnel wall hit (for compositing depth comparisons)

layout(set = 2, binding = 0, rgba16f) restrict uniform writeonly image2D tunnelColor;
layout(set = 2, binding = 1, r32f)    restrict uniform writeonly image2D tunnelDepth;

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

vec3 shadeTunnelWall(Voxel voxel, vec3 hitPos, ivec3 grid_position, vec3 normal, int step_count, vec3 ray_dir) {
    vec3 voxel_pos = vec3(grid_position) * voxelWorldProperties.scale;
    vec3 voxel_view_dir = normalize(cameraParams.position.xyz - voxel_pos);

    float emission = getVoxelEmission(voxel);
    vec3 color = getVoxelColor(voxel, grid_position) * (1.0 + emission);

    if (emission < 1.0) {
        // Shadow ray from the tunnel wall — this naturally handles the case where
        // the sun can't reach the tunnel interior (shadow will be 0 for enclosed tunnels).
        float shadow = computeShadow(hitPos, normal, voxelWorldProperties.sun_direction.xyz) * debug.shadow_intensity;

        // AO inside tunnels tends to be heavy, which actually looks good — it sells the
        // enclosed feel. We use the same intensity as the surface pass for consistency.
        float ao = computeAmbientOcclusion(hitPos, grid_position, normal);
        ao = mix(1.0, ao, debug.ao_intensity) * 0.7 + 0.3;

        color = ao * blinnPhongShading(color, normal, normalize(voxelWorldProperties.sun_direction.xyz),
            voxelWorldProperties.sun_color.rgb, voxel_view_dir, shadow);
    }

    return color;
}

// ----------------------------------- MAIN -----------------------------------
// Trace sequence: air → solid (terrain) → air (tunnel) → solid (far wall)
//                  |-- trace 1 --|        |-- trace 2 --|   |-- trace 3 --|
//                  front-face             back-face          front-face
//
// We render trace 3's hit: the solid wall visible inside the tunnel cavity.

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
    float nudge = 0.001; // small offset to avoid re-hitting the same surface

    // Clear outputs (no tunnel found)
    imageStore(tunnelColor, pos, vec4(0.0));
    imageStore(tunnelDepth, pos, vec4(range_far));

    // Voxel voxel; float t; ivec3 gp; vec3 n; int steps;
    // bool hit = voxelTraceBackfaceWorld(ray_origin, ray_dir, vec2(0.0, 100.0), voxel, t, gp, n, steps);
    // imageStore(tunnelColor, ivec2(gl_GlobalInvocationID.xy), hit ? vec4(1,0,0,1) : vec4(0,0,1,1));
    
    // if (hit) {
    //     vec3 hitPos = ray_origin + t * ray_dir;
    //     n = normalize(n);
    //     n = -n;

    //     vec3 color = getVoxelColor(voxel, gp);
    //     // color = shadeVoxel(voxel, hitPos, gp, n, steps, ray_dir);

    //     imageStore(tunnelColor, pos, vec4(color, 1.0));
    // } else {
    // imageStore(tunnelColor, pos, vec4(sampleSkyColor(ray_dir), 1.0));
    // }

    // ---- Trace 1: Find terrain entry (front face) ----
    Voxel v1; float t1; ivec3 gp1; vec3 n1; int s1;
    bool hitTerrain = voxelTraceWorld(ray_origin, ray_dir,
        vec2(range_near, range_far), v1, t1, gp1, n1, s1);

    if (!hitTerrain) return;

    // ---- Trace 2: Find terrain exit into tunnel cavity (back face) ----
    // Start just past the front-face hit, looking for where the ray exits solid.
    float remaining2 = range_far - t1;
    if (remaining2 <= 0.0) return;

    vec3 origin2 = ray_origin + t1 * ray_dir + ray_dir * nudge;
    Voxel v2; float t2; ivec3 gp2; vec3 n2; int s2;
    bool hitExit = voxelTraceBackfaceWorld(origin2, ray_dir,
        vec2(0.0, remaining2), v2, t2, gp2, n2, s2);

    if (!hitExit) return;

    // ---- Trace 3: Find the tunnel's far wall (front face again) ----
    // Start just past the back-face exit, now in the air cavity of the tunnel.
    float totalSoFar = t1 + nudge + t2;
    float remaining3 = range_far - totalSoFar;
    // if (remaining3 <= 0.0) return;

    // imageStore(tunnelColor, pos, vec4(max(remaining3, 0.0) / range_far, max(-remaining3, 0.0) / range_far, 0.0, 1.0));
    // return;

    vec3 debugColor = vec3(1.0);
    bool hitWall = false;
    vec3 origin3 = origin2 + t2 * ray_dir + ray_dir * nudge;
    
    if (remaining3 > 0.0) {
        Voxel v3; float t3; ivec3 gp3; vec3 n3; int s3;
        hitWall = voxelTraceWorld(origin3, ray_dir,
            vec2(0.0, remaining3), v3, t3, gp3, n3, s3);

        // bool isEmpty = isVoxelAir(v3);
        // debugColor = mix(vec3(1,0,0), vec3(0,1,0), float(hitWall));
        debugColor = vec3(float(v3.data & 1u), 0.0, 0.0);
        // debugColor = mix(vec3(1,0,0), vec3(0,1,0), 0);
    }

    vec3 worldSize = vec3(voxelWorldProperties.grid_size.xyz) * voxelWorldProperties.scale;
    vec3 normPos = origin3 / worldSize;
    
    imageStore(tunnelColor, pos, vec4(debugColor, 1.0));

    // imageStore(tunnelColor, pos, vec4(normPos, 1.0));
    return;



    // if (!hitWall) return;

    // ---- Shade the tunnel wall ----
    // float totalT = totalSoFar + nudge + t3; // total world-space distance from camera
    // vec3 hitPos = origin3 + t3 * ray_dir;
    // n3 = normalize(n3);

    // vec3 color = shadeTunnelWall(v3, hitPos, gp3, n3, s3, ray_dir);
    vec3 color = getVoxelColor(v2, gp2);
    // if (hitWall) color = vec3(1.0, 1.0, 0.0);

    // vec3 color = (vec3(1.0, 0.0, 0.0));

    imageStore(tunnelColor, pos, vec4(color, 1.0));
    imageStore(tunnelDepth, pos, vec4(1.0));
    // imageStore(tunnelDepth, pos, vec4(totalT));
}
