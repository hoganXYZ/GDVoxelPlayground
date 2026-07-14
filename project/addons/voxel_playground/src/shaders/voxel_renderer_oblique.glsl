#[compute]
#version 460

#include "utility.glsl.inc"
#include "voxel_world.glsl.inc"
#include "voxel_elements.glsl.inc"

// Set to 1 to draw on-screen debug values and tint miss pixels by cause
// (red = ray never reached the world AABB, blue heat = traversed but empty).
#define DEBUG_OVERLAY 0
#include "debug_print.glsl.inc"

// ----------------------------------- OBLIQUE PROJECTION SETTINGS -----------------------------------
//
// Oblique projection = orthographic projection + a shear: every pixel fires a ray
// with the SAME direction (parallel rays, so no perspective convergence), but that
// shared direction is tilted relative to the image plane. Deeper geometry gets
// drawn shifted across the screen toward OBLIQUE_ANGLE_DEGREES, giving the classic
// cavalier/cabinet "pixel-art" look where you see both the top and front of things.

// Screen direction (degrees, counter-clockwise from screen-right) that receding
// depth is drawn toward. 45 = depth recedes toward the upper-right.
#define OBLIQUE_ANGLE_DEGREES 270.0

// How far one unit of depth shifts across the screen.
// 0.0 = pure orthographic, 0.5 = cabinet projection, 1.0 = cavalier projection.
#define OBLIQUE_STRENGTH 1.0

// Distance (world units) at which the oblique framing matches what the perspective
// camera would see. The camera's fov property acts as a zoom control: view height
// on screen = 2 * tan(fov/2) * OBLIQUE_FOCUS_DISTANCE.
#define OBLIQUE_FOCUS_DISTANCE 60.0
 
// Pull ray origins back along the camera forward axis (world units). With parallel
// rays the whole image plane is the "camera", so if part of that plane pokes into
// terrain those pixels start inside voxels; pulling back avoids that without
// moving the camera node.
#define OBLIQUE_PULLBACK 0.0

// ----------------------------------- GENERAL STORAGE -----------------------------------

layout(set = 1, binding = 0, rgba8) restrict uniform writeonly image2D outputImage;
layout(set = 1, binding = 1, r32f) restrict uniform writeonly image2D depthBuffer;

layout(std430, set = 1, binding = 2) restrict buffer Params {
    vec4 background; //rgb, brightness
    int width;
    int height;
    float fov;
} params;

layout(std430, set = 1, binding = 3) restrict buffer Camera {
    mat4 view_projection;
    mat4 inv_view_projection;
    vec4 position;
    uint frame_index;
    float near;
    float far;
} camera;


// ----------------------------------- FUNCTIONS -----------------------------------

vec3 blinnPhongShading(vec3 baseColor, vec3 normal, vec3 lightDir, vec3 lightColor, vec3 viewDir, float shadow) {
    float NdotL = max(dot(normal, lightDir), 0.0);

    vec3 diffuse = NdotL * baseColor;

    vec3 specular = vec3(0.0);
    vec3 H = normalize(lightDir + viewDir);
    float NdotH = max(dot(normal, H), 0.0);
    specular = pow(NdotH, 10.0) * lightColor * 0.0;

    vec3 ambient = baseColor;

    vec3 result = 0.25 * shadow * specular; // 0.25
    result += (1.0) * diffuse; //(shadow * 0.5 + 0.5) * diffuse;
    result += 0.3 * ambient; // ambient light

    // Overriding and just returning base color
    // result = baseColor;
    return result;
}

vec3 unproject(mat4 inv_vp, vec3 ndc) {
    vec4 p = inv_vp * vec4(ndc, 1.0);
    return p.xyz / p.w;
}

// 32x32 = 1024 threads/group silently fails on the macOS Metal backend
// (register-heavy kernel lowers the per-pipeline thread limit below 1024).
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;
void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    if (pos.x >= params.width || pos.y >= params.height) return;

    vec2 screen_uv = vec2(pos + 0.5) / vec2(params.width, params.height);

    vec2 ndc_xy = screen_uv * 2.0 - 1.0;
    ndc_xy.y = -ndc_xy.y;

    // Reconstruct the camera basis from the perspective view-projection matrix by
    // unprojecting far-plane points (reverse-Z: ndc z = 0 is the far plane), so no
    // new CPU-side data is needed.
    mat4 inv_vp = inverse(camera.view_projection);
    vec3 far_center = unproject(inv_vp, vec3(0.0, 0.0, 0.0));
    vec3 far_right  = unproject(inv_vp, vec3(1.0, 0.0, 0.0));
    vec3 far_up     = unproject(inv_vp, vec3(0.0, 1.0, 0.0));
    vec3 forward = normalize(far_center - camera.position.xyz);
    vec3 right = normalize(far_right - far_center);
    vec3 up = normalize(far_up - far_center);

    // Parallel rays: origins spread across a view plane through the camera position,
    // all sharing one sheared direction.
    float aspect = float(params.width) / float(params.height);
    float half_height = tan(radians(params.fov) * 0.5) * OBLIQUE_FOCUS_DISTANCE;
    float half_width = half_height * aspect;

    vec3 ray_origin = camera.position.xyz
        + right * (ndc_xy.x * half_width)
        + up * (ndc_xy.y * half_height)
        - forward * OBLIQUE_PULLBACK;

    // Shearing the shared ray direction opposite the screen shear makes geometry at
    // depth d appear shifted by d * OBLIQUE_STRENGTH toward OBLIQUE_ANGLE_DEGREES.
    float oblique_angle = radians(OBLIQUE_ANGLE_DEGREES);
    vec2 shear = OBLIQUE_STRENGTH * vec2(cos(oblique_angle), sin(oblique_angle));
    vec3 ray_dir = normalize(forward - right * shear.x - up * shear.y);

    ivec3 grid_position;
    vec3 normal;
    int step_count = 0;
    float t;
    vec3 color = vec3(0.0);

    Voxel voxel;

    bool hit = voxelTraceWorld(ray_origin, ray_dir, vec2(camera.near, camera.far + OBLIQUE_PULLBACK), voxel, t, grid_position, normal, step_count);
    float depth = 0.0;

    // No voxel hit — sky color and far-plane depth
    if (!hit) {
        color = sampleSkyColor(ray_dir);
#if DEBUG_OVERLAY
        // Why did this ray miss? Red = it never even intersected the world's
        // AABB (framing/origin problem). Blue heat = it traversed the volume
        // but found nothing (empty world data / occupancy problem).
        vec3 bounds_max = vec3(voxelWorldProperties.brick_grid_size.xyz) * (voxelWorldProperties.scale * BRICK_EDGE_LENGTH);
        vec3 inv_dir = 1.0 / max(abs(ray_dir), vec3(1e-4)) * sign(ray_dir);
        vec3 tA = (vec3(0.0) - ray_origin) * inv_dir;
        vec3 tB = (bounds_max - ray_origin) * inv_dir;
        float t_entry = max(max(min(tA.x, tB.x), min(tA.y, tB.y)), min(tA.z, tB.z));
        float t_exit  = min(min(max(tA.x, tB.x), max(tA.y, tB.y)), max(tA.z, tB.z));
        if (t_entry > t_exit || t_exit < 0.0)
            color = mix(color, vec3(1.0, 0.0, 0.0), 0.35);
        else
            color = mix(color, vec3(0.0, 0.3, 1.0), min(float(step_count) / 64.0, 1.0) * 0.5);
#endif
    } else {

    // Voxel hit — compute depth and shade
    vec3 hitPos = ray_origin + t * ray_dir;

    // Project hit point to clip space for NDC depth (reverse-Z: near=1, far=0).
    // Screen position won't match the oblique image, but the value is still a valid,
    // monotonic depth of the hit point for occlusion tests.
    vec4 clipPos = camera.view_projection * vec4(hitPos, 1.0);
    depth = clipPos.z / clipPos.w;

    normal = normalize(normal);
    vec3 voxel_pos = vec3(grid_position) * voxelWorldProperties.scale;
    float emission = getElementEmission(voxel);
    color = getVoxelColor(voxel, grid_position) * (1 + emission);
    if(isVoxelLiquid(voxel))
    {
        color += vec3(0.05 * sin(0.0167 * voxelWorldProperties.frame + 0.2 * (grid_position.x + grid_position.y + grid_position.z)));
        color += vec3(((voxel.data & 0xFu) > 0) ? 0.5 : 0);
    }

    // With parallel rays every pixel shares the same view direction.
    vec3 voxel_view_dir = -ray_dir;

    // direct illumination
    if(emission < 1) {
        vec3 albedo = color;

        float voxelSize = voxelWorldProperties.scale;
        vec3 flatHitPos = voxel_pos + (vec3(0.5) + normal * 0.501) * voxelSize;

        float shadow = computeShadow(flatHitPos, normal, voxelWorldProperties.sun_direction.xyz);
        float ao = computeAmbientOcclusion(hitPos, grid_position, normal) * 0.7 + 0.3;
        // override ao for now
        //ao = 1.0;
        // override shadow for now
        shadow = 1.0;
        color = ao * blinnPhongShading(color, normal, normalize(voxelWorldProperties.sun_direction.xyz), voxelWorldProperties.sun_color.rgb, voxel_view_dir, shadow);
        color += computePointLights(albedo, flatHitPos, normal, voxel_view_dir);
    }

    // Brush preview overlay
    if (voxelWorldProperties.brush_preview_position.w > 0) {
        vec3 brush_center = voxelWorldProperties.brush_preview_position.xyz;
        float brush_radius = voxelWorldProperties.brush_preview_radius;
        float dist_to_brush = length(vec3(grid_position) - brush_center);

        if (dist_to_brush < brush_radius) {
            float shell_thickness = max(1.0, brush_radius * 0.15);
            float shell_dist = abs(dist_to_brush - brush_radius);
            float shell = 1.0 - smoothstep(0.0, shell_thickness, shell_dist);

            float interior = 1.0 - smoothstep(0.0, brush_radius, dist_to_brush);

            float highlight = shell * 0.4 + interior * 0.08;
            color = mix(color, vec3(1.0), highlight);
        }
    }

    } // end hit

#if DEBUG_OVERLAY
    {
        // Lines: 0 camera position, 1 forward, 2 shared ray dir, 3 world AABB max,
        // 4 view-plane half extents, 5 (fov, scale, frame), 6 this pixel's step count.
        float bg = debugBg(pos, 7, 36);
        if (bg > 0.0) color *= 0.25;
        float dbg = 0.0;
        dbg += debugVec3(pos, 0, camera.position.xyz);
        dbg += debugVec3(pos, 1, forward);
        dbg += debugVec3(pos, 2, ray_dir);
        dbg += debugVec3(pos, 3, vec3(voxelWorldProperties.brick_grid_size.xyz) * (voxelWorldProperties.scale * BRICK_EDGE_LENGTH));
        dbg += debugVec2(pos, 4, vec2(half_width, half_height));
        dbg += debugVec3(pos, 5, vec3(params.fov, voxelWorldProperties.scale, float(voxelWorldProperties.frame)));
        dbg += debugInt(pos, 6, step_count);
        if (dbg > 0.0) color = vec3(1.0);
    }
#endif

    imageStore(outputImage, pos, vec4(color, 1.0));
    imageStore(depthBuffer, pos, vec4(depth, 0.0, 0.0, 0.0));
}
