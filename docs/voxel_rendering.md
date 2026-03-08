# Voxel World Rendering

## Architecture Overview

The renderer is a fully GPU-driven voxel raymarcher built as a Godot 4 GDExtension. There is no traditional mesh geometry — every pixel is rendered by casting a ray from the camera through a voxel grid and shading the first hit.

**Pipeline flow:**

1. **C++ (`VoxelWorld`)** — Allocates GPU buffers for bricks, voxel data, and world properties on the `RenderingDevice`
2. **GDScript (`VoxelCompositorEffect`)** — Runs on the render thread as a `CompositorEffect`, packs camera parameters, and dispatches the compute shader
3. **GLSL compute shader** — Raymarches the voxel grid, shades hits, and writes directly to the scene color buffer

Two renderer paths exist:
- **Compositor renderer** (`voxel_compositor_renderer.glsl`) — Integrates with Godot's compositor pipeline, writes to `rgba16f` output image. This is the active path.
- **Standalone renderer** (`voxel_renderer.glsl`) — Older path that also writes a depth buffer. Uses `rgba8` output and computes `inverse(camera.view_projection)` per-pixel rather than receiving a precomputed inverse.

---

## Data Structures

### Voxel (32-bit packed uint)

```
Bits [31–24]  Type     (8 bits)   — VOXEL_TYPE_AIR/SOLID/WATER/LAVA/SAND/VINE
Bits [23–8]   Color    (16 bits)  — HSV compressed (see Color System below)
Bits [7–0]    Energy   (8 bits)   — Per-type data (vine growth energy, water flow)
```

Defined in `voxel_world.glsl:59-64`. Created via `createVoxel(type, color)`. Type extracted with `(data >> 24) & 0xFF`, color with `(data >> 8) & 0xFFFF`.

### Brick

```glsl
struct Brick {
    uint occupancy_count;      // number of non-air voxels (0 = skip during raytrace)
    uint voxel_data_pointer;   // index into the flat voxel array (in units of BRICK_VOLUME)
};
```

Each brick covers an **8×8×8** region of the grid (512 voxels). Bricks are stored in a flat array indexed by `(bx + by * grid_w + bz * grid_w * grid_h)`.

### VoxelWorldProperties

Uniform buffer at binding 0 containing:
- `grid_size` / `brick_grid_size` — World dimensions in voxels and bricks
- `sky_color`, `ground_color`, `sun_color`, `sun_direction` — Environment lighting
- `scale` — World-space size of one voxel
- `frame` — Frame counter (drives ping-pong buffer and animation)
- `brush_preview_position` / `brush_preview_radius` — Editor brush overlay

---

## Brick-Map Acceleration Structure

The world is divided into a uniform grid of bricks. Each brick has an `occupancy_count` — when zero, the raymarcher skips the entire 8³ region in a single step. This gives a two-level acceleration structure:

1. **Coarse level:** Step through bricks (each step covers 8 voxels)
2. **Fine level:** When an occupied brick is hit, trace individual voxels within it

### Morton Ordering

Voxels within each brick are stored in **Z-order (Morton) curve** rather than linear order (`voxel_world.glsl:194-208`). This interleaves the x/y/z bits:

```
morton = x0 | y0 | z0 | x1 | y1 | z1 | x2 | y2 | z2
```

Morton ordering improves GPU cache coherence because spatially adjacent voxels map to nearby memory addresses.

---

## Two-Level DDA Raymarching

Both levels use DDA (Digital Differential Analyzer) grid traversal — stepping along the ray one grid cell at a time, always advancing along the axis with the smallest `tMax`.

### World-Level Trace (`voxelTraceWorld`)

`voxel_world.glsl:259-340`

1. Compute ray-AABB intersection against the full world bounds. Early-out if the ray misses.
2. Initialize DDA state at brick-grid scale (`brick_scale = scale * 8`).
3. For each brick along the ray:
   - Skip if `occupancy_count == 0`
   - Otherwise, transform the ray into local brick coordinates and call `voxelTraceBrick`
   - If a voxel is hit, return it with the world-space `t`, grid position, and surface normal
4. Step to the next brick along the ray. Cap at `MAX_RAY_STEPS = 1000`.

### Brick-Level Trace (`voxelTraceBrick`)

`voxel_world.glsl:225-257`

Traces through an 8×8×8 grid in voxel-local coordinates. Same DDA algorithm but at single-voxel resolution. Returns the voxel index, local grid position, and accumulated `t`.

### Normal Estimation

Normals are determined by which face the ray entered through — tracked by recording the negative of the step direction on each DDA step (`normal = -ray_step`). This gives axis-aligned normals suitable for voxel rendering.

---

## Ping-Pong Dual Buffer System

Two identical voxel data buffers (`voxelData` at binding 2, `voxelData2` at binding 3) enable lock-free simulation updates. The frame counter determines which buffer is "current" and which is "previous":

```glsl
// Even frames: read voxelData, write voxelData2 (for simulation)
// Odd frames:  read voxelData2, write voxelData
Voxel getVoxel(uint index) {
    return frame % 2 == 0 ? voxelData[index] : voxelData2[index];
}
```

- `getVoxel()` / `getPreviousVoxel()` — Read from current/previous frame
- `setVoxel()` / `setPreviousVoxel()` — Write to current/previous frame
- `setBothVoxelBuffers()` — Write to **both** buffers (required for editor operations to avoid flicker)

The renderer always reads via `getVoxel()`, so it sees the latest committed state.

---

## Lighting Model

### Blinn-Phong Shading

`voxel_compositor_renderer.glsl:36-52`

```glsl
result  = 0.25 * shadow * specular;        // specular: (N·H)^10
result += (shadow * 0.5 + 0.5) * diffuse;  // half-shadow preserves some diffuse
result += 0.2 * ambient;                   // constant ambient term
```

- **Diffuse:** `N·L * baseColor`
- **Specular:** `(N·H)^10 * sunColor` (hardness = 10)
- **Shadow attenuation:** Shadows dim diffuse to 50% (not fully black) and reduce specular to 0

### Shadow Rays

`voxel_world.glsl:350-353`

A secondary `voxelTraceWorld` call from the hit point toward `sun_direction`. If any voxel is hit (beyond a self-intersection epsilon of 0.001), the point is in shadow. Binary shadow — no soft shadows or penumbra.

### Ambient Occlusion

`voxel_world.glsl:365-412`

Per-vertex AO sampling inspired by the Minecraft-style technique:

1. Determine the dominant normal axis to pick two tangent directions (`d1`, `d2`)
2. Sample 8 neighbors in the plane above the hit face: 4 edge-adjacent (sides) and 4 diagonal (corners)
3. Compute per-corner AO: `(side1 + side2 + max(corner, side1 * side2)) / 3.0`
4. Bilinearly interpolate the 4 corner AO values based on the hit position within the voxel face

The AO factor is then scaled: `ao * 0.7 + 0.3` (never fully occluded).

### Emissive Voxels

Lava voxels return `emission = 1.0`. When emission is active:
- Color is boosted: `color * (1 + emission)` (doubles brightness)
- Shadow and AO are skipped entirely

---

## Color System

### 16-bit HSV Compression

`utility.glsl` — `compress_color16` / `decompress_color16`

Colors are stored as 16 bits packed into the voxel data:

```
Bits [15–9]  Hue         (7 bits, 128 levels)
Bits [8–5]   Saturation  (4 bits, 16 levels)
Bits [4–0]   Value       (5 bits, 32 levels)
```

Conversion: RGB → HSV → quantize → pack. Decompression reverses the process.

### Randomized Color Variation

`randomizedColor()` in `utility.glsl` applies per-voxel HSV jitter using a position-based hash. This prevents flat-looking surfaces by introducing subtle color variation while keeping the base hue recognizable.

---

## Camera Setup and Ray Generation

### Camera Buffer

Packed by `voxel_compositor_effect.gd` each frame (176 bytes):

| Field | Size | Description |
|-------|------|-------------|
| `view_projection` | 64B | Camera VP matrix |
| `inv_view_projection` | 64B | Precomputed inverse VP |
| `position` | 16B | World-space camera position |
| `frame_index` | 4B | Frame counter |
| `near_plane` | 4B | Near clip (0.01) |
| `far_plane` | 4B | Far clip (1000.0) |
| `width`, `height` | 4B each | Render target dimensions |

### Ray Generation

`voxel_compositor_renderer.glsl:59-67`

```glsl
vec2 screen_uv = vec2(pos + 0.5) / vec2(width, height);  // pixel center
vec4 ndc = vec4(screen_uv * 2.0 - 1.0, 0.0, 1.0);       // to NDC
vec4 world_pos = inv_view_projection * ndc;                // unproject
world_pos /= world_pos.w;                                  // perspective divide
vec3 ray_dir = normalize(world_pos.xyz - camera_position);
```

Each pixel gets its own ray. The compute shader dispatches in **32×32 thread groups**, with `ceil(width/32) × ceil(height/32)` groups covering the full render target.

---

## Visual Effects

### Liquid Animation

`voxel_compositor_renderer.glsl:83-87`

Water and lava voxels get a time-varying color oscillation:
```glsl
color += 0.05 * sin(0.0167 * frame + 0.2 * (gx + gy + gz));
```
Additionally, the lower 4 bits of voxel data are checked — if nonzero, a `+0.5` brightness boost is applied (flow visualization).

### Brush Preview

`voxel_compositor_renderer.glsl:99-114`

When `brush_preview_position.w > 0`, a spherical overlay is rendered:
- **Shell highlight:** Bright ring at the sphere surface (`shell * 0.4`)
- **Interior fill:** Subtle white tint inside (`interior * 0.08`)
- Shell thickness is 15% of brush radius (min 1 voxel)

### Sky Rendering

`voxel_world.glsl:343-348`

When a ray misses all voxels:
- Vertical gradient between `ground_color` and `sky_color` based on ray Y direction
- Sun disc: `pow(dot(ray_dir, sun_direction), 50)` — tight specular highlight blended with `sun_color`

---

## Debug Visualization

A separate debug renderer (`voxel_compositor_renderer_debug.glsl`) supports multiple visualization modes via push constants:

| Mode | Visualization |
|------|---------------|
| 0 | Normal rendering |
| 1 | Surface normals |
| 2 | Depth heatmap |
| 3 | Ray step count (0–200 steps) |
| 4 | Voxel type colors |
| 5 | AO only |
| 6 | Shadow only |
| 7 | Brick grid overlay |

Additional features: X-ray (layered transparency), clipping sphere/plane, and edge highlighting.
