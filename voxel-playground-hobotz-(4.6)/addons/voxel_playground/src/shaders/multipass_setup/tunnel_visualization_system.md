# Tunnel X-Ray Visualization System

## Overview

This system renders tunnels and cavities hidden inside voxel terrain by using a three-pass GPU compute pipeline: a **surface pass** (standard rendering), a **tunnel pass** (finds and shades tunnel interiors), and a **composite pass** (blends them together with an x-ray effect).

The core idea is that a tunnel is defined by the ray transition **air → solid → air → solid**. The final solid surface in that sequence is the tunnel's far wall, which is what we render.

## Architecture

```
Surface Pass ──→ surfaceColor (rgba16f)
                  surfaceDepth (r32f)
                                         ──→ Composite Pass ──→ finalOutput (rgba16f)
Tunnel Pass  ──→ tunnelColor  (rgba16f)
                  tunnelDepth  (r32f)
```

All three passes share the same camera buffer (set 1, binding 0) and voxel world buffers (set 0, bindings 0-3). Each pass has its own push constants and output image bindings.

## Pass Details

### 1. Surface Pass (`surface_pass.glsl`)

Standard front-face voxel raytrace. Identical to the existing renderer but outputs to two images instead of one:

- **surfaceColor** (rgba16f): shaded color in rgb, alpha 1.0 for geometry, 0.0 for sky.
- **surfaceDepth** (r32f): world-space ray t value. Set to `clip_far` for sky pixels.

Uses `voxelTraceWorld` (front-face only). Includes full shading: Blinn-Phong lighting, shadow rays, ambient occlusion, edge highlighting.

Push constants: same `DebugParams` struct as the existing debug shader.

### 2. Tunnel Pass (`tunnel_pass.glsl`)

Performs three sequential ray traces per pixel to find tunnel interiors:

```
Trace 1 (front-face):  Find where the ray enters terrain.
                        Uses voxelTraceWorld.
                        If miss → no tunnel, early out.

Trace 2 (back-face):   Starting from trace 1's hit + small nudge along the ray,
                        find where the ray exits solid into the tunnel cavity.
                        Uses voxelTraceBackfaceWorld.
                        If miss → solid extends to world edge, no tunnel, early out.

Trace 3 (front-face):  Starting from trace 2's exit + small nudge,
                        find the tunnel's far wall (solid surface inside the cavity).
                        Uses voxelTraceWorld.
                        If miss → open cavity with no far wall, early out.
```

Each trace starts where the previous one ended, with a small nudge (`0.001`) along the ray to avoid re-hitting the same surface. The remaining range is decremented accordingly so we don't trace past `clip_far`.

Outputs:
- **tunnelColor** (rgba16f): shaded tunnel wall in rgb, alpha 1.0 if tunnel found, 0.0 if not.
- **tunnelDepth** (r32f): total world-space distance from camera to the tunnel wall hit.

Both outputs are cleared to zero/`clip_far` at the start of each pixel, so pixels with no tunnel are clean.

The tunnel wall is shaded with the same Blinn-Phong + shadow + AO pipeline as the surface. Shadow rays from tunnel walls will naturally return 0 for enclosed tunnels (the sun can't reach them), which gives a convincingly dark interior.

Push constants: same `DebugParams` struct.

### 3. Composite Pass (`composite_pass.glsl`)

Reads all four images from the previous passes and blends them. For pixels where `tunnelColor.a == 0`, the surface is passed through unchanged. Where tunnels exist:

1. The surface color is desaturated and darkened (makes the terrain "recede").
2. The tunnel color is optionally tinted (e.g., warm orange for caves).
3. The two are blended based on tunnel opacity and a depth fade.
4. An optional outline is drawn at tunnel region boundaries using a 3x3 neighbor alpha check.

Push constants (`CompositeParams`):

| Parameter | Type | Description |
|---|---|---|
| `tunnel_opacity` | float | Master alpha for x-ray effect. 0 = hidden, 1 = full. Start with 0.7. |
| `surface_desaturation` | float | How much to gray out the surface over tunnels. Start with 0.4. |
| `surface_darken` | float | How much to darken the surface over tunnels. Start with 0.3. |
| `tunnel_tint_strength` | float | Blend toward tint color. 0 = no tint. Start with 0.3. |
| `tunnel_tint_color` | vec4 | Tint color. Warm: `(1.0, 0.85, 0.6, 1.0)`. Cool: `(0.6, 0.8, 1.0, 1.0)`. |
| `depth_fade_start` | float | Distance where tunnel starts fading. Start with 50.0. |
| `depth_fade_end` | float | Distance where tunnel fully disappears. Start with 200.0. |
| `outline_strength` | float | White edge at tunnel boundaries. 0 = off. Start with 0.3. |

## Godot Integration

### Image Setup

You need four intermediate images, all matching the viewport resolution:

```
surfaceColor  — FORMAT_RGBAH (rgba16f)
surfaceDepth  — FORMAT_RF    (r32f)
tunnelColor   — FORMAT_RGBAH (rgba16f)
tunnelDepth   — FORMAT_RF    (r32f)
finalOutput   — FORMAT_RGBAH (rgba16f)
```

### Dispatch Order

Each frame:

```
1. Surface Pass
   - Bind: voxel world (set 0), camera (set 1), surfaceColor + surfaceDepth (set 2)
   - Dispatch: ceil(width/32) × ceil(height/32) × 1

2. Tunnel Pass
   - Bind: voxel world (set 0), camera (set 1), tunnelColor + tunnelDepth (set 2)
   - Dispatch: ceil(width/32) × ceil(height/32) × 1
   - Barrier: wait for surface pass if tunnel pass reads surface depth (current version doesn't, but future versions might)

3. Composite Pass
   - Bind: camera (set 1), all four images as readonly + finalOutput as writeonly (set 2)
   - Dispatch: ceil(width/32) × ceil(height/32) × 1
   - Barrier: must wait for both surface and tunnel passes to complete
```

The surface and tunnel passes are independent of each other and could theoretically run in parallel, but in practice the GPU will schedule them sequentially since they both read the same voxel data. A barrier before the composite pass is required.

### Binding Layout for Composite Pass

The composite pass expects set 2 to have 5 bindings:

```
binding 0: surfaceColor  (readonly,  rgba16f)
binding 1: surfaceDepth  (readonly,  r32f)
binding 2: tunnelColor   (readonly,  rgba16f)
binding 3: tunnelDepth   (readonly,  r32f)
binding 4: finalOutput   (writeonly, rgba16f)
```

### Push Constant Structs

Surface and tunnel passes both use the existing `DebugParams` push constant struct (64 bytes).

The composite pass uses a new `CompositeParams` struct (48 bytes):

```c
struct CompositeParams {
    float tunnel_opacity;
    float surface_desaturation;
    float surface_darken;
    float tunnel_tint_strength;
    vec4  tunnel_tint_color;
    float depth_fade_start;
    float depth_fade_end;
    float outline_strength;
    float _pad0;
};
```

## Important Notes

### Normal Convention

The backface trace (`voxelTraceBackfaceWorld`) returns normals with the **opposite sign** from the front-face trace. Front-face normals point back toward the ray (`-ray_step`), backface normals point along the ray (`+ray_step`). The tunnel pass only shades trace 3 (a front-face hit), so normals are correct without flipping. If you ever shade the backface exit point (trace 2), you must negate the normal before passing it into shadow/AO/lighting.

### Performance

The tunnel pass is the most expensive part — it runs up to three full ray traversals per pixel. For optimization:

- Early-out pixels where the surface pass found sky (no terrain = no tunnel). You could pass `surfaceDepth` as a readonly input to the tunnel pass and skip pixels where depth == `clip_far`.
- Render the tunnel pass at half resolution and upsample in the composite.
- Limit the tunnel pass range to something shorter than `clip_far` since distant tunnels won't be visible anyway after depth fade.

### Nudge Value

The `0.001` nudge between traces prevents re-hitting the same surface. If your voxel scale is very small (< 0.01), you may need to reduce this. If you see tunnel walls "leaking" through thin terrain (1-2 voxels thick), increase it slightly.

### Included Shader Files

- `surface_pass.glsl` — surface rendering pass
- `tunnel_pass.glsl` — tunnel detection and shading pass
- `composite_pass.glsl` — final compositing pass
- `voxel_world.glsl` — shared voxel world code (includes the backface trace with bug fixes and documentation)

All four files should be placed in the same shader directory. The surface and tunnel passes both `#include "utility.glsl"` and `#include "voxel_world.glsl"`.
