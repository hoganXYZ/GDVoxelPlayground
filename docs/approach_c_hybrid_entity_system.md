# Approach C: Hybrid Entity System

CPU owns decisions. GPU owns movement, pheromones, and voxel edits.

---

## System Hierarchy

```
VoxelWorld::update(delta)
│
├── 1. Properties buffer upload (frame counter, sun, etc.)
│
├── 2. VoxelWorldUpdatePass (liquid, freeze_lava, vine_growth, cleanup)
│
├── 3. EntityMovementPass [NEW - GPU]
│   ├── Reads: entity buffer, voxel data (previous frame)
│   ├── Writes: voxel data (current frame) via atomicCompSwap
│   ├── Per entity: attempt move toward target, resolve collisions
│   └── Uses setBothVoxelBuffers() for voxel edits (tunneling, building)
│
├── 4. PheromonePass [NEW - GPU]
│   ├── 4a. Deposit sub-pass (1 thread per entity)
│   │   └── Writes pheromone intensity at entity position based on state
│   ├── 4b. Diffusion + Decay sub-pass (1 thread per pheromone cell)
│   │   └── intensity = intensity * (1 - decay) + avg(neighbors) * diffusion
│   └── Buffer: half-res grid (64^3), uint16 per cell per type, ~2MB total
│
├── 5. CellPondUpdatePass (existing cellular automata)
│
├── 6. EntityReadbackPass [NEW - GPU→CPU]
│   ├── Async readback of entity buffer (positions, states)
│   ├── Async readback of pheromone samples at entity positions
│   └── Results arrive next frame (1-frame delay, imperceptible at 60fps)
│
└── 7. EntityAIUpdate [NEW - CPU]
    ├── Reads: last frame's readback (entity positions, pheromone samples)
    ├── Runs per entity: order update, capability logic, squad coordination
    ├── Runs pathfinding for entities that need new paths
    ├── Writes: updated targets/orders to entity upload buffer
    └── Uploads changed entity targets to GPU (partial buffer update)
```

---

## Data Structures

### GPU Entity Buffer (uploaded/read back each frame)

```glsl
struct GPUEntity {                    // 32 bytes, tightly packed
    ivec4 position_and_state;         // xyz = grid position, w = packed state
    ivec4 target_and_type;            // xyz = move target,   w = packed type info
};
// w of position_and_state:
//   bits [31-24] entity_type (ant worker, ant soldier, etc.)
//   bits [23-16] current_state (idle, moving, digging, carrying, fighting)
//   bits [15-8]  carry_type (voxel type being carried, 0 = empty)
//   bits [7-0]   health

// w of target_and_type:
//   bits [31-24] order_type (move, attack, gather, build, follow_trail, idle)
//   bits [23-16] flags (can_dig, can_swim, etc. — capability summary for GPU)
//   bits [15-0]  squad_id
```

**500 entities * 32B = 16KB.** Upload and readback of 16KB per frame is negligible.

### CPU Entity (full game object)

```
Entity
├── id: uint16                        (matches GPU buffer index)
├── blueprint: &UnitBlueprint         (shared type data)
├── capabilities: [Capability]        (combat, carrier, builder, emitter, sensor)
├── current_order: Order              (long-running command with start/update/cancel)
├── squad: &Squad?                    (group membership)
├── path: [Vector3i]                  (cached A* result, re-pathed when stale)
├── pheromone_samples: [float; 4]     (FOOD, HOME, DANGER, RECRUIT — from readback)
└── gpu_index: uint16                 (index into GPUEntity buffer)
```

### Pheromone Grid (GPU only, sampled via readback)

```glsl
// 4 pheromone types * 64^3 cells * 2 bytes = 2MB
// Binding: set 1, one buffer per type, or interleaved as uint16[4] per cell (8 bytes)
layout(std430, set = 1, binding = 0) buffer PheromoneGrid {
    uint data[];  // 2x uint16 packed per uint, 64^3 * 2 uints per type
} pheromoneGrids[4];
```

Each pheromone cell covers a 2x2x2 voxel region. To convert entity grid position to pheromone cell: `pheromone_pos = entity_pos / 2`.

---

## Frame Lifecycle (Detailed)

```
Frame N:
  CPU:
    1. Read async results from frame N-1 (entity positions, pheromone samples)
    2. For each entity:
       - Feed pheromone samples into PheromoneSensor
       - Tick current_order.update(delta) → Running | Succeeded | Failed
       - If no order: consult priority stack (direct > squad > pheromone > idle)
       - If order produced a new move target: mark entity dirty
    3. For dirty entities: pathfind if needed, compute next waypoint
    4. Build partial upload: only dirty entity targets (typically 10-50 per frame)
    5. Upload dirty entity targets to GPU entity buffer

  GPU (dispatched sequentially):
    6. EntityMovementPass: for each entity, attempt atomicCompSwap toward target
    7. PheromoneDepositPass: for each entity, deposit based on state
    8. PheromoneDiffusePass: for each cell, decay + diffuse
    9. Kick off async readback of entity buffer + pheromone samples

Frame N+1:
    Results from step 9 arrive. Back to step 1.
```

---

## Ordering Rules (Entity Pass vs. Automata)

The entity movement pass runs AFTER liquid/cleanup but BEFORE cellpond. This means:

- Liquid/sand physics resolve first — entities don't fight gravity simulations.
- Entity voxel writes (`setBothVoxelBuffers`) are visible to cellpond rules the same frame.
- Automata shaders must skip entity voxels. Add an `isVoxelEntity()` type check:

```glsl
bool isVoxelEntity(Voxel v) {
    return getVoxelType(v) >= VOXEL_TYPE_ENTITY_START; // e.g., type >= 8
}
```

Insert this guard at the top of `liquid.glsl`, `vine_growth.glsl`, `cellpond_rules.glsl`:

```glsl
if (isVoxelEntity(voxel_value)) return;  // don't simulate entity voxels as terrain
```

---

## Development Guardrails

### What MUST Stay on the GPU

| Operation | Why |
|-----------|-----|
| Entity movement (atomicCompSwap) | Collision resolution between 500 entities must be parallel. Sequential CPU CAS is 500x slower. |
| Pheromone diffusion + decay | 262K cells * 6 neighbors = 1.5M reads per frame per type. Trivial for GPU, expensive for CPU. |
| Pheromone deposit | Must happen in the same pass as movement to avoid an extra sync point. |
| Voxel edits from entities | `setBothVoxelBuffers()` must happen on the GPU thread that owns the voxel buffers. |

### What MUST Stay on the CPU

| Operation | Why |
|-----------|-----|
| Order selection and state machines | Complex branching, string lookups, capability queries. GPUs hate divergent control flow. |
| Pathfinding (A*, flow field generation) | Per-entity A* requires dynamic-length open sets. GPUs cannot allocate per-thread variable-size memory. |
| Squad coordination | Iterating member lists, role assignment, shared pathfinding. Irregular data structures. |
| Blueprint/capability queries | Pointer chasing through type objects. Cache-hostile on GPU. |
| Spawn/despawn logic | Changing the entity count means resizing or compacting the GPU buffer. Do this on CPU, upload the new buffer. |

### What CAN Live on Either Side (Choose Based on Profiling)

| Operation | GPU if... | CPU if... |
|-----------|-----------|-----------|
| Pheromone gradient sampling | Entity count > 1000 (batch sample in movement shader) | Entity count < 500 (sample 6 neighbors per entity in readback) |
| Local obstacle sensing | Already in the movement shader (check neighbors before CAS) | Need more than 6-neighbor sensing for complex terrain analysis |
| Flow field generation | Multiple targets with many entities each (BFS wavefront shader) | Few targets, or targets change every frame (CPU BFS is simpler to iterate on) |
| Entity-to-entity distance checks | Large radius checks across all entities (spatial hash on GPU) | Small squads checking 5-10 nearby allies (CPU array scan) |

### Performance Red Flags

**Stop and profile if you see any of these:**

1. **Per-entity GPU readback.** Never call `buffer_get_data()` in a loop for individual entities. Always read the entire entity buffer in one async call. The existing `get_voxel_at()` method does per-voxel sync reads — this pattern does NOT scale to 500 entities per frame.

2. **Sync readback in the update loop.** `buffer_get_data()` is synchronous and stalls the CPU until the GPU finishes. Use `buffer_get_data_async()` (available in GDCS) for all entity/pheromone reads. Accept the 1-frame delay.

3. **Uploading the full entity buffer every frame.** Only upload dirty entries. If 10 entities changed targets this frame, upload 10 * 32B = 320 bytes, not 16KB. Use `buffer_update()` with byte offset.

4. **More than 2 CPU-GPU sync points per frame.** The current pipeline has zero explicit syncs (all passes dispatch without `submitAndSync=true`). Adding entity readback adds one async operation. If you find yourself adding `submitAndSync=true` between passes, the pipeline is over-synchronized. Combine passes or use barriers instead.

5. **Entity AI taking > 2ms per frame.** 500 entities * basic order tick should take < 0.5ms. If it's over 2ms, pathfinding is the likely culprit. Solutions: stagger pathfinding (re-path 50 entities per frame on a round-robin), use flow fields for common targets, cache paths and only invalidate on voxel edits near the path.

6. **Pheromone grid resolution matching voxel grid.** A 128^3 pheromone grid is 2M cells per type — 4x the necessary resolution. Half-res (64^3) captures the same gradients at 1/8 the cost. If you need finer resolution later, profile first.

7. **Growing the entity buffer at runtime.** Pre-allocate for max entities (e.g., 2048 * 32B = 64KB). Use an active_count uniform to limit dispatch. Never resize GPU buffers mid-game — it requires destroying and recreating the buffer, invalidating all uniform sets.

8. **Entity shader with high branch divergence.** If different entity types need fundamentally different movement logic (flyers vs. diggers vs. swimmers), do NOT branch in a single shader. Instead, dispatch separate shaders per movement class, or encode movement rules as data (allowed directions, can_dig flag) and keep the shader branchless.

9. **Pathfinding every entity every frame.** A* in a 128^3 grid can take 0.1-1ms per query depending on path length. At 500 entities, that's 50-500ms. Solutions:
   - Stagger: re-path 25-50 entities per frame, round-robin
   - Cache: paths are valid until voxel edits occur nearby
   - Flow fields: one pathfind per target, shared by all entities heading there
   - Hierarchical: brick-level A* (4096 nodes) then within-brick refinement

10. **Entities writing voxels without `setBothVoxelBuffers()`.** Using `setVoxel()` alone causes 2-frame flicker because the other ping-pong buffer retains stale data. This is the single most common bug in this codebase — always use `setBothVoxelBuffers()` for any edit that should persist.

---

## Debug Tools

### 1. Entity Visualization (Renderer Debug Mode)

Add a new viz_mode to `voxel_compositor_renderer_debug.glsl` (currently modes 0-9 exist):

**Mode 10: Entity Overlay**
- During raymarching, when a voxel hit has `isVoxelEntity()`, colorize by entity state:
  - Idle = gray
  - Moving = blue
  - Digging = orange
  - Carrying = green
  - Fighting = red
- Decode state from the voxel energy bits (same 8-bit packed state as the GPU entity buffer).
- This requires zero extra buffers — just a color lookup in the existing ramarcher.

**Mode 11: Entity Targets**
- Bind the GPU entity buffer as an additional uniform in the debug renderer.
- For each pixel, after raymarching finds a hit position, check if any entity's target matches that cell. If so, draw a small marker.
- Alternatively, render entity paths as colored voxel trails (write translucent path markers into a debug overlay buffer).

Implementation: extend the `viz_mode` push constant enum in `voxel_compositor_debug_effect.gd` and add cases to the debug shader's switch statement.

### 2. Pheromone Field Visualization

**Compositor overlay approach** (follows the tunnel effect's multi-pass pattern):

Create `VoxelCompositorPheromoneEffect` as a new compositor effect:
1. Bind pheromone grid buffer(s) alongside voxel world buffers.
2. During raymarching, at each step, sample the pheromone grid at the current position.
3. Blend pheromone intensity as a colored fog/glow overlaid on the voxel scene:
   - FOOD_TRAIL = green glow
   - HOME_TRAIL = yellow glow
   - DANGER = red glow
   - RECRUITMENT = blue glow
4. Intensity maps to alpha (faint trails = translucent, strong trails = opaque).

**Push constant controls:**
```glsl
float pheromone_viz_type;      // which type to display (-1 = all)
float pheromone_viz_intensity;  // brightness multiplier
float pheromone_viz_threshold;  // hide values below this (reduce noise)
```

**Simpler alternative** — CPU readback + GDScript particles:
- Each frame, async-read a 2D slice of the pheromone grid (e.g., y = entity_avg_height).
- In GDScript, spawn `GPUParticles3D` or draw `ImmediateMesh` quads at cells above threshold.
- Slower but requires no new shaders. Good for early prototyping.

### 3. Navigation Debug

**Path visualization:**
- On the CPU side, each entity holds a `path: [Vector3i]`. To visualize:
  - Use Godot's `ImmediateMesh` or `MeshInstance3D` with `BoxMesh` to draw path waypoints as small cubes in the 3D scene.
  - Color-code by path age (fresh = bright, stale = dim) to spot entities running on expired paths.
  - Toggle via a GDScript debug flag on the entity manager node.

**Flow field visualization:**
- Flow fields are direction vectors per brick (16^3 = 4096 entries).
- Read the flow field buffer back to CPU (4096 * 4B = 16KB, cheap).
- Draw arrows at each brick center using `ImmediateMesh` lines pointing in the flow direction.
- Color-code by distance-to-target (gradient from blue=far to red=near).

**Brick occupancy heatmap:**
- Already computed by `cleanup_pass.glsl` — `occupancy_count` per brick.
- Add a debug viz_mode that colors bricks by occupancy (green=empty, red=full).
- Read the brick buffer (4096 * 8B = 32KB) and display as a 3D grid of colored cubes, or add a shader mode that tints ramarched voxels by their brick's occupancy.

**Pathfinding step count overlay:**
- When an A* search runs, record the number of nodes expanded.
- Display as a text overlay (reuse the `fps_meter.gd` pattern): `"pathfinds/frame: 12, avg nodes: 340, max: 1200"`.
- This is critical for catching Red Flag #9 (pathfinding every entity every frame).

### 4. GPU Performance Profiling

**Frame time breakdown:**
- Godot's RenderingDevice doesn't expose GPU timestamps directly, but you can bracket each compute dispatch with CPU-side timing:

```cpp
// In VoxelWorld::update()
uint64_t t0 = OS::get_singleton()->get_ticks_usec();
_entity_movement_pass->update(delta);
uint64_t t1 = OS::get_singleton()->get_ticks_usec();
_pheromone_pass->update(delta);
uint64_t t2 = OS::get_singleton()->get_ticks_usec();
// ... expose t1-t0, t2-t1 to GDScript as properties
```

This measures CPU submission time, not GPU execution time, but spikes here indicate pipeline stalls (GPU not finished when CPU tries to submit next pass).

**Entity buffer stats overlay:**
- Track and display per frame:
  - `active_entities: 487 / 2048`
  - `dirty_uploads: 23 (736 bytes)`
  - `readback_latency: 1 frame`
  - `move_successes: 412 / 487` (from a counter in the movement shader — use `atomicAdd` on a stats uint)
  - `move_collisions: 75 / 487`
- Expose via a small stats buffer (16 bytes) read back async alongside the entity buffer.

**Movement shader collision counter:**
```glsl
layout(std430, set = 2, binding = 0) buffer EntityStats {
    uint move_attempts;
    uint move_successes;
    uint move_blocked_terrain;
    uint move_blocked_entity;
} entityStats;

// In movement shader, after atomicCompSwap:
atomicAdd(entityStats.move_attempts, 1u);
if (cas_succeeded)
    atomicAdd(entityStats.move_successes, 1u);
else if (target_was_solid)
    atomicAdd(entityStats.move_blocked_terrain, 1u);
else
    atomicAdd(entityStats.move_blocked_entity, 1u);
```

Read back this 16-byte buffer once per frame async. Display in the debug overlay.

### 5. Entity Inspector (GDScript UI)

Follow the pattern from `rule_editor.gd` — a panel that shows details for a selected entity:

- Click on a voxel → `raycast_world()` → if the hit voxel is an entity type → show:
  - Entity ID, type (from blueprint name)
  - Current order (name + sub-state)
  - Squad ID and squad order
  - Path (length, age in frames, next waypoint)
  - Pheromone readings (4 values from last readback)
  - Health, carry state
- Highlight the entity's path and target in the 3D view.
- Highlight the entity's pheromone deposit trail (last N positions stored on CPU).

### 6. Slow-Motion and Step Mode

Leverage the existing `simulation_enabled` bool on VoxelWorld:

- **Pause**: set `simulation_enabled = false`, also pause entity AI updates.
- **Step**: run one frame of simulation + entity AI, then pause again.
- **Slow-mo**: run entity AI at 1/4 rate (tick every 4th frame). Movement shader still runs every frame but entities only update targets every 4th frame, so they move slowly toward stale targets.
- Bind to keyboard shortcuts in `player_controller.gd` (e.g., P = pause, period = step, minus/plus = speed).

This is the single most valuable debug tool. Most entity bugs are invisible at 60fps but obvious when stepping frame-by-frame.

---

## Key Files to Modify

| File | Change |
|------|--------|
| `src/voxel_world/voxel_world.h` | Add `EntityMovementPass*`, `PheromonePass*`, entity buffer RID, AI update method |
| `src/voxel_world/voxel_world.cpp` | Add passes to `init()` and `update()` in correct order |
| `shaders/voxel_world.glsl.inc` | Add `VOXEL_TYPE_ENTITY_START`, `isVoxelEntity()`, entity struct definition |
| `shaders/automata/liquid.glsl` | Add `isVoxelEntity()` early-exit guard |
| `shaders/automata/cellpond_rules.glsl` | Add `isVoxelEntity()` early-exit guard |
| `src/gdcs/include/gdcs.h` | Already has everything needed (async readback, buffer update with offset) |
| `voxel_compositor_debug_effect.gd` | Add entity and pheromone viz_mode enum entries |
| `voxel_compositor_renderer_debug.glsl` | Add entity/pheromone coloring cases |

### New Files

| File | Purpose |
|------|---------|
| `shaders/entity/entity_movement.glsl` | Movement + collision via atomicCompSwap |
| `shaders/entity/pheromone_deposit.glsl` | Per-entity pheromone writes |
| `shaders/entity/pheromone_diffuse.glsl` | Grid-wide decay + diffusion |
| `src/voxel_world/entity/entity_movement_pass.h/.cpp` | C++ compute pass wrapper |
| `src/voxel_world/entity/pheromone_pass.h/.cpp` | C++ pheromone compute pass wrapper |
| `src/entity_system/entity.h` | CPU entity struct (order, capabilities, path) |
| `src/entity_system/entity_manager.h/.cpp` | CPU-side AI loop, buffer upload/readback |
| `src/entity_system/orders/*.h` | MoveOrder, GatherOrder, etc. |
