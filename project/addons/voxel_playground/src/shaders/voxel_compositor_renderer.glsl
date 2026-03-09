#[compute]
#version 460

#include "utility.glsl.inc"
#include "voxel_world.glsl.inc"

// ----------------------------------- STRUCTS -----------------------------------

struct Light {
    vec4 position;
    vec4 color;
};

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

// ----------------------------------- OUTPUT -----------------------------------

layout(set = 2, binding = 0, rgba16f) restrict uniform writeonly image2D outputImage;

// ----------------------------------- FUNCTIONS -----------------------------------

vec3 blinnPhongShading(vec3 baseColor, vec3 normal, vec3 lightDir, vec3 lightColor, vec3 viewDir, float shadow) {
    float NdotL = max(dot(normal, lightDir), 0.0);

    vec3 diffuse = NdotL * baseColor;

    vec3 specular = vec3(0.0);
    vec3 H = normalize(lightDir + viewDir);
    float NdotH = max(dot(normal, H), 0.0);
    specular = pow(NdotH, 10.0) * lightColor;

    vec3 ambient = baseColor;

    vec3 result = 0.25 * shadow * specular;
    result += (shadow * 0.5 + 0.5) * diffuse;
    result += 0.2 * ambient;
    return result;
}

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;
void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    if (pos.x >= cameraParams.width || pos.y >= cameraParams.height) return;

    vec2 screen_uv = vec2(pos + 0.5) / vec2(cameraParams.width, cameraParams.height);

    vec4 ndc = vec4(screen_uv * 2.0 - 1.0, 0.0, 1.0);
    // ndc.y = -ndc.y;

    vec4 world_pos = cameraParams.inv_view_projection * ndc;
    world_pos /= world_pos.w;
    vec3 ray_origin = cameraParams.position.xyz;
    vec3 ray_dir = normalize(world_pos.xyz - ray_origin);
    ivec3 grid_position;
    vec3 normal;
    int step_count = 0;
    float t;
    vec3 color = vec3(0.0);

    Voxel voxel;

    if (voxelTraceWorld(ray_origin, ray_dir, vec2(cameraParams.near_plane, cameraParams.far_plane), voxel, t, grid_position, normal, step_count)) {
        vec3 hitPos = ray_origin + t * ray_dir;
        normal = normalize(normal);
        vec3 voxel_pos = vec3(grid_position) * voxelWorldProperties.scale;
        vec3 baseColor = vec3(grid_position) / voxelWorldProperties.grid_size.xyz;
        float emission = getVoxelEmission(voxel);
        color = getVoxelColor(voxel, grid_position) * (1 + emission);
        if(isVoxelLiquid(voxel))
        {
            color += vec3(0.05 * sin(0.0167 * voxelWorldProperties.frame + 0.2 * (grid_position.x + grid_position.y + grid_position.z)));
            color += vec3(((voxel.data & 0xFu) > 0) ? 0.5 : 0);
        }

        vec3 voxel_view_dir = normalize(cameraParams.position.xyz - voxel_pos);

        // direct illumination
        if(emission < 1) {
            float shadow = computeShadow(hitPos, normal, voxelWorldProperties.sun_direction.xyz);
            float ao = computeAmbientOcclusion(hitPos, grid_position, normal) * 0.7 + 0.3;
            color = ao * blinnPhongShading(color, normal, normalize(voxelWorldProperties.sun_direction.xyz), voxelWorldProperties.sun_color.rgb, voxel_view_dir, shadow);
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
    } else {
        color = sampleSkyColor(ray_dir);
    }

    imageStore(outputImage, pos, vec4(color, 1.0));
}
