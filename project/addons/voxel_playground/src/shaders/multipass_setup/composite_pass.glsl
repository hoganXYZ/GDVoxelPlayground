#[compute]
#version 460

// ----------------------------------- CAMERA -----------------------------------

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

// ----------------------------------- COMPOSITE PARAMS (push constants) -----------------------------------

layout(push_constant) uniform CompositeParams {
    float tunnel_opacity;       // 0.0 = hidden, 1.0 = full tunnel overlay
    float surface_desaturation; // how much to desaturate the surface where tunnels show through
    float surface_darken;       // how much to darken the surface where tunnels show through
    float tunnel_tint_strength; // blend toward a tint color for tunnel walls

    vec4 tunnel_tint_color;     // tint color for tunnel walls (e.g. warm orange for cave feel)

    float depth_fade_start;     // tunnel fades out beyond this distance
    float depth_fade_end;       // tunnel fully invisible beyond this distance
    float outline_strength;     // edge outline where tunnel meets non-tunnel pixels
    float debug_view_mode;      // 0=composite, 1=surface color, 2=surface depth, 3=tunnel color, 4=tunnel depth, 5=tunnel mask
} composite;

// ----------------------------------- INPUTS -----------------------------------

layout(set = 2, binding = 0, rgba16f) restrict uniform readonly  image2D surfaceColor;
layout(set = 2, binding = 1, r32f)    restrict uniform readonly  image2D surfaceDepth;
layout(set = 2, binding = 2, rgba16f) restrict uniform readonly  image2D tunnelColor;
layout(set = 2, binding = 3, r32f)    restrict uniform readonly  image2D tunnelDepth;

// ----------------------------------- OUTPUT -----------------------------------

layout(set = 2, binding = 4, rgba16f) restrict uniform writeonly image2D finalOutput;

// ----------------------------------- HELPERS -----------------------------------

vec3 desaturate(vec3 color, float amount) {
    float lum = dot(color, vec3(0.2126, 0.7152, 0.0722));
    return mix(color, vec3(lum), amount);
}

// Simple 3x3 neighbor check: is this pixel on the border of a tunnel region?
float tunnelOutline(ivec2 pos) {
    float center = imageLoad(tunnelColor, pos).a;
    float diff = 0.0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            float neighbor = imageLoad(tunnelColor, pos + ivec2(dx, dy)).a;
            diff += abs(center - neighbor);
        }
    }
    return clamp(diff, 0.0, 1.0);
}

// ----------------------------------- MAIN -----------------------------------

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;
void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    if (pos.x >= cameraParams.width || pos.y >= cameraParams.height) return;

    vec4 surface = imageLoad(surfaceColor, pos);
    vec4 tunnel  = imageLoad(tunnelColor, pos);
    float surfaceDist = imageLoad(surfaceDepth, pos).r;
    float tunnelDist = imageLoad(tunnelDepth, pos).r;

    // ---- Debug solo views ----
    int viewMode = int(composite.debug_view_mode);
    if (viewMode == 1) {
        // Surface color solo
        imageStore(finalOutput, pos, vec4(surface.rgb, 1.0));
        return;
    } else if (viewMode == 2) {
        // Surface depth heatmap
        float d = clamp(surfaceDist / composite.depth_fade_end, 0.0, 1.0);
        vec3 heatmap = mix(vec3(0.0, 0.4, 1.0), vec3(1.0, 0.2, 0.0), d);
        if (surface.a == 0.0) heatmap = vec3(0.0); // sky = black
        imageStore(finalOutput, pos, vec4(heatmap, 1.0));
        return;
    } else if (viewMode == 3) {
        // Tunnel color solo (black where no tunnel)
        imageStore(finalOutput, pos, vec4(tunnel.rgb * tunnel.a, 1.0));
        return;
    } else if (viewMode == 4) {
        // Tunnel depth heatmap (black where no tunnel)
        float d = clamp(tunnelDist / composite.depth_fade_end, 0.0, 1.0);
        vec3 heatmap = mix(vec3(0.0, 1.0, 0.4), vec3(1.0, 0.0, 0.5), d);
        if (tunnel.a == 0.0) heatmap = vec3(0.0);
        imageStore(finalOutput, pos, vec4(heatmap, 1.0));
        return;
    } else if (viewMode == 5) {
        // Tunnel mask (white = tunnel found, black = no tunnel)
        imageStore(finalOutput, pos, vec4(vec3(tunnel.a), 1.0));
        return;
    }

    // ---- Normal composite (viewMode == 0) ----
    bool hasTunnel = tunnel.a > 0.0;

    if (!hasTunnel) {
        // No tunnel behind this pixel — pass through surface unchanged
        imageStore(finalOutput, pos, surface);
        return;
    }

    // ---- Tunnel exists behind this surface ----

    // Distance-based fade: tunnels far from the camera fade out
    float depthFade = 1.0;
    if (composite.depth_fade_end > composite.depth_fade_start) {
        depthFade = 1.0 - smoothstep(composite.depth_fade_start, composite.depth_fade_end, tunnelDist);
    }

    float tunnelAlpha = composite.tunnel_opacity * depthFade;

    // Prepare the tunnel color with optional tint
    vec3 tunnelShaded = tunnel.rgb;
    if (composite.tunnel_tint_strength > 0.0) {
        tunnelShaded = mix(tunnelShaded, tunnelShaded * composite.tunnel_tint_color.rgb, composite.tunnel_tint_strength);
    }

    // Prepare the surface color — desaturate and darken where tunnel shows through
    vec3 surfaceMod = surface.rgb;
    surfaceMod = desaturate(surfaceMod, composite.surface_desaturation * tunnelAlpha);
    surfaceMod *= mix(1.0, 1.0 - composite.surface_darken, tunnelAlpha);

    // Blend: modified surface with tunnel showing through
    vec3 result = mix(surfaceMod, tunnelShaded, tunnelAlpha);

    // Optional outline at tunnel region boundaries
    if (composite.outline_strength > 0.0) {
        float outline = tunnelOutline(pos);
        result = mix(result, vec3(1.0), outline * composite.outline_strength * tunnelAlpha);
    }

    imageStore(finalOutput, pos, vec4(result, 1.0));
}
