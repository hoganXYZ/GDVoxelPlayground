# Runtime-Definable Cellular Automata — Design

Goal: replace the hand-written, one-shader-per-behavior automata passes
(`liquid.glsl`, `freeze_lava.glsl`, `vine_growth.glsl`) with a Sandboxels-style
**data-driven element system** where new materials, movement behaviors, and
reactions can be formulated at runtime — from GDScript, an in-game editor, or
saved resources — without touching C++ or hand-writing GLSL for the common
cases.

## Implementation status (2026-07-11)

Phases 1–3 are implemented and verified end-to-end (`project/tests/test_ca.tscn`
runs 11 automated checks: liquid/powder movement, quench reaction → steam, a
runtime-registered acid that dissolves rock, a runtime cloner built from
behavior ops, and ice melting through heat diffusion + phase change).

| Piece | Where |
|---|---|
| GPU tables + aux channel | `shaders/voxel_elements.glsl.inc`, set 1 bindings 8–12 |
| Generic movement pass (Tier 1 + Tier 3 ops) | `shaders/automata/movement.glsl`, two checkerboard sub-passes |
| Reaction/thermal/life/phase pass (Tier 2) | `shaders/automata/reaction.glsl`, runs on its own buffer flip |
| Resources & table builder | `src/voxel_world/cellular_automata/voxel_element*.{h,cpp}` |
| Pipeline dispatch | `voxel_world_update_pass.cpp`; `VoxelWorld::update` flips the frame twice per tick |
| Defaults (water/lava/sand/vine + steam/ice/fire/glass) | `VoxelElementSet::create_default()` |

Runtime usage from GDScript:

```gdscript
var acid := VoxelElement.new()
acid.element_name = "acid"
acid.movement_class = VoxelElement.MOVEMENT_LIQUID
acid.density = 1100.0
acid.base_color = Color(0.6, 0.9, 0.2)
acid.add_reaction("solid", "", "air", 0.4)      # partner dissolves
var id := world.element_set.add_element(acid)     # tables re-upload automatically
world.edit_world(origin, dir, radius, range,      # paint it
    (id << 24) | (1 << 16) | color16)
```

Mutating an existing element's properties does not emit `changed`; call
`world.upload_elements()` afterwards. Tier 4 (per-element custom GLSL codegen)
and the in-game editor UI remain future work; `vine_growth.glsl` still runs as
the hand-written CUSTOM-class example.

Known quirks: `voxelTraceWorld` misses on perfectly axis-aligned rays
(pre-existing; nudge the direction), CHANGE/DELETE behavior ops on diagonal
offsets can very rarely duplicate a concurrently-moving target, and renderer
emission still keys off the lava type byte rather than the element table.

This document has three parts: (1) how Sandboxels actually manages its CA,
(2) what does and doesn't survive the move to a parallel GPU voxel grid,
(3) the proposed architecture and phased plan for this repo.

---

## Part 1 — How Sandboxels manages its cellular automata

(Dissected from the live source, `index.html` in R74nCom/sandboxels; line refs
are to that file as of 2026-07.)

### 1.1 One dictionary, everything is data

Every material is an entry in a single flat `elements` dictionary. The engine
never special-cases an element by name in the core loop; it iterates whatever
is in the dictionary. Mods and runtime element creation are literally
`elements.my_thing = {...}` — this is the entire extensibility story, and it
works because every engine system reads *properties* off the element record:

```js
"sand": {
    color: "#e6d577",
    behavior: behaviors.POWDER,          // movement (preset fn or 3x3 DSL grid)
    reactions: {                         // contact chemistry: partner -> outcome
        "water": {elem1:"wet_sand", elem2:null},
        "tornado": {elem1:"sandstorm", oneway:true},
    },
    tempHigh: 1700, stateHigh: "molten_glass",   // phase transition
    category: "land", state: "solid", density: 1602
}
```

The property vocabulary is the system. The important groups:

| Group | Properties | Consumed by |
|---|---|---|
| Movement | `behavior`, `behaviorOn`, `state`, `density`, `viscosity` | `pixelTick` + `tryMove` |
| Chemistry | `reactions` map | `tryMove` → `reactPixels` |
| Thermal | `temp`, `tempHigh/stateHigh`, `tempLow/stateLow`, `insulate` | `doHeat` → `pixelTempCheck` |
| Fire | `burn`, `burnTime`, `burnInto`, `fireColor`, `extinguish` | `doBurning` |
| Electric | `conduct`, `behaviorOn`, `colorOn`, `superconductAt` | `doElectricity` |
| Escape hatch | `tick(pixel)`, `onMix`, `onCollide`, `onStateHigh`, ... | tick loop hooks |

### 1.2 Movement: presets + a tiny declarative DSL

`behaviors` is a library of movement patterns. The hot ones (POWDER, LIQUID,
GAS) are hardcoded JS fast paths; everything exotic uses a **3×3 grid DSL**
centered on the pixel, with two-letter opcodes per cell:

```js
POWDER_OLD: [ "XX|XX|XX",
              "XX|XX|XX",
              "M2|M1|M2" ]   // try straight down first, then diagonals
```

Opcodes (interpreted in `pixelTick`, handlers in `behaviorRules` @ ~15368):
`M1`/`M2` move priority 1/2, `SW` swap, `SP` support (don't fall if present),
`DL`/`DB` delete other/both, `CH:a>b` change neighbor, `CR:elem` create,
`CL` clone self, `CF` cloner-fetch, `HT:n`/`CO:n` heat/cool. Modifiers:
`%chance`, `:arg`, `A AND B`. Grids can be flipped/rotated per pixel.

Interpretation collects candidate spots (`move1Spots`, `move2Spots`,
`swapSpots`, `supportSpots`), then resolves with fixed priority:
support-veto → swap → shuffled move1 → shuffled move2. The DSL is why users
can invent elements at runtime: it's data, not code.

### 1.3 Reactions fire on *contact attempts*, not a separate pass

`tryMove(pixel, nx, ny)` (@ ~15042) is the heart. If the destination is
occupied, it tries, in order:

1. `reactions[targetElement]` of the mover (`reactPixels` @ ~14811) — a rich
   record: `elem1`/`elem2` (what each side becomes; `null` = delete; arrays =
   random pick), `chance`, `tempMin/tempMax`, `charge1/2`, `temp1/2` (heat
   released), `color1/2`, `attr1/2` (attach arbitrary per-pixel state),
   `oneway`, and `func` as an escape hatch.
2. The reverse reaction (target's table, unless `oneway`).
3. **Density swap**: if the (state, state) pair is in `validDensitySwaps` and
   mover is denser, swap with probability `(d1-d2)/(d1+d2)` — this one rule
   gives sinking, floating, and immiscibility for free.
4. `onMoveInto` / `onCollide` hooks.

So chemistry is *keyed by ordered element pair* and *triggered by adjacency +
motion pressure*. That coupling is what makes powders "stir" reactions.

### 1.4 Universal passes: heat, fire, electricity

After movement, every pixel gets the default systems (`doDefaults` @ ~15930):

- **Heat** (`doHeat`): average temp with right+bottom neighbors only
  (visits each pair once), skip `insulate`. Then `pixelTempCheck`: if
  `temp >= tempHigh` → become `stateHigh` (supports arrays, multi-threshold
  `extraTempHigh`, color multipliers, `onStateHigh` hook); same for low. This
  is how ice/water/steam, melting, and glass all work — one mechanism.
- **Fire** (`doBurning`): `burning` flag + start tick; spreads to neighbors
  with `burn`% chance; `extinguish` materials quench; after `burnTime` the
  pixel becomes `burnInto` (default fire); emits fire pixels upward.
- **Electricity** (`doElectricity`): charge propagates through `conduct`
  neighbors, failed conduction heats (resistance), a `chargeCD` refractory
  cooldown stops immediate re-conduction, `behaviorOn`/`colorOn` switch
  behavior/appearance while charged.

Temperature, burning, and charge are **per-pixel state**, not per-element
state — pixels are JS objects that can carry arbitrary attributes.

### 1.5 The tick pipeline and fairness

`tickPixels` (@ ~17076) each frame:

1. Copy + **shuffle** the pixel list (removes directional scan bias), then
   stable-sort by optional `updateOrder`.
2. Per pixel: world-edge behavior → custom `tick()` hook → mod hooks
   (`runPerPixelList`) → `pixelTick` (behavior DSL + defaults).
3. A `pixel.start === pixelTicks` guard prevents a pixel that moved into
   not-yet-scanned territory from updating twice in one tick.

### 1.6 What to take away

Sandboxels ≈ **element property table** + **movement presets/DSL** +
**pair-keyed contact reaction table** + **three universal field systems
(heat/fire/charge)** + **escape-hatch code hooks**. Roughly 90% of its ~500
elements are pure data through the first four mechanisms; the escape hatch
covers the last 10% (humans, birds, lasers, portals).

---

## Part 2 — What survives the move to a parallel 3D GPU grid

Current infra in this repo (all of which stays):

- Voxel = 32-bit uint: type byte (bits 24–31 ⇒ **256 element ids**), 16-bit
  color (bits 8–23), 8 aux bits (bits 0–7; today: liquid direction memory,
  vine energy). `voxel_world.glsl.inc`, `voxel_properties.h`.
- **Double-buffered** voxel SSBOs with `frame % 2` parity; movement claims the
  destination with `atomicCompSwap` and vacates the source on success;
  on failure the cell persists itself (`liquid.glsl`).
- Invariant: static content is identical in both buffers
  (`setBothVoxelBuffers`); each dynamic pass persists or moves what it owns.
- Brick map (8³, Morton) with occupancy maintained by `cleanup_pass.glsl`.
- `gdcs` compiles GLSL → SPIR-V **at runtime** with its own `#include`
  resolution and `args` injection (`gdcs.cpp:50`,
  `shader_compile_spirv_from_source`) — runtime shader codegen is already a
  supported path, used every launch.

Mapping Sandboxels concepts:

| Sandboxels | GPU translation | Cost |
|---|---|---|
| `elements` dictionary | Element property table in an SSBO, indexed by type byte | trivial — instant runtime updates |
| POWDER/LIQUID/GAS presets, `state`+`density` | One generic movement kernel switching on a per-element *movement class* | replaces `liquid.glsl` |
| `reactions` pair table | Flat reaction-rule array + per-element offset/count index, evaluated in a dedicated pass | replaces `freeze_lava.glsl` |
| `temp` + `tempHigh/Low` | Per-voxel aux buffer (temperature field) + threshold check in the reaction pass | new aux SSBO pair |
| `burn`/`burnInto` | Flags in aux buffer + rules in the same passes | free once aux exists |
| 3×3 behavior DSL | 27-neighborhood **behavior bytecode**, interpreted per voxel | new small pass |
| `tick(pixel)` JS escape hatch | Per-element GLSL snippets, code-generated into a pass and compiled at runtime | `vine_growth.glsl` becomes the first instance |
| Shuffled update order | Per-voxel hash RNG (already used) + atomic claims (already used) | none |
| Sequential conflict resolution | `atomicCompSwap` claims for moves; **pair-symmetric RNG** for reactions (below) | design care, not perf |

What fundamentally does *not* port: arbitrary sequential JS mutating distant
pixels mid-scan (`floodPixels`, humans walking, recursive electricity). Those
stay out of scope for the data system; the codegen escape hatch (Tier 4) or a
CPU-side pass covers them if ever needed.

---

## Part 3 — Proposed architecture

Four tiers, one schema. Tiers 1–3 are pure data (SSBO uploads, zero shader
recompilation, instant at runtime). Tier 4 is runtime-compiled GLSL.

```
┌────────────────────────────────────────────────────────────┐
│ VoxelElementSet (Godot Resource, editable at runtime)      │
│   VoxelElement[] ── properties, reactions, behavior ops,   │
│                     optional GLSL snippet                  │
└──────────────┬─────────────────────────────┬───────────────┘
        to_gpu_tables()                generate_glsl()
               │                             │ (Tier 4 only)
               ▼                             ▼
   ┌───────────────────────┐    ┌─────────────────────────┐
   │ SSBOs:                │    │ shader_compile_spirv_   │
   │  element_table[256]   │    │ from_source → hot-swap  │
   │  reaction_rules[]     │    │ custom pass pipeline    │
   │  behavior_ops[]       │    └─────────────────────────┘
   └───────────────────────┘
```

### 3.1 GPU data model

**Voxel word stays 32-bit** (renderer untouched). Formalize the low byte as
element-defined scratch (direction memory, growth energy — as today).

**New aux buffer pair** (`uint` per voxel, double-buffered like voxelData):

```
bits  0–15  temperature, fixed point: kelvin*16 (0–4095 K, 1/16 K steps)
bits 16–23  life/fuel counter (burn timer, gas dissipation, growth budget)
bits 24–31  flags: burning, charged, charge-cooldown(2), reserved(4)
```

At the default 128³ world this is 8 MB ×2 — cheap, and it unlocks the entire
thermal/fire/charge vocabulary.

**Element table** — `elements[256]`, std430, uploaded on any change:

```glsl
struct ElementDef {
    uint  movement_class;   // STATIC | POWDER | LIQUID | GAS | CUSTOM(=skip)
    float density;          // drives swaps within/between classes
    float flow;             // liquid lateral persistence / viscosity analog
    float initial_temp;     // kelvin
    uint  temp_high_q;      // threshold (same fixed point as aux)
    uint  state_high;       // element id to become (0xFFFF = none)
    uint  temp_low_q;
    uint  state_low;
    uint  burn_chance;      // 0-100; 0 = fireproof
    uint  burn_time;        // ticks before burn-out
    uint  burn_into;        // element id (default: fire-like gas)
    uint  conduct;          // 0-255 electrical conductivity
    uint  flags;            // insulate, extinguisher, glow, ...
    float emission;         // renderer: replaces hardcoded lava check
    vec2  base_color;       // packed; used when spawned by rules
    uint  reaction_offset;  // into reaction_rules[]
    uint  reaction_count;
    uint  behavior_offset;  // into behavior_ops[] (Tier 3)
    uint  behavior_count;
};
```

**Reaction rules** — Sandboxels' `reactions` map flattened. Stored per acting
element, sorted, first-match-wins (mirrors the `RULES` table already proven in
the falling-sand-alchemy repo):

```glsl
struct ReactionRule {
    uint partner;        // element id, or ANY_HOT / ANY_LIQUID class wildcard
    uint self_becomes;   // element id | KEEP | DELETE(=air)
    uint partner_becomes;// informational; enforced by partner's mirror rule
    uint chance;         // per-contact per-tick, 0-10000 (0.01% steps)
    uint temp_min_q, temp_max_q;  // gate on own temperature
    int  temp_delta_q;   // heat released/absorbed on fire
    uint flags;          // needs_burning, oneway, set_life, ...
    uint aux_seed;       // initial life/aux for the product
};
```

**Behavior ops (Tier 3)** — the 3×3 DSL generalized to 3D as bytecode instead
of strings. Per element, a short list (cap ~16) of:

```glsl
struct BehaviorOp {
    uint packed_offset;  // 27-neighborhood offset, 2 bits/axis
    uint opcode;         // MOVE1 MOVE2 SWAP SUPPORT DELETE CHANGE CREATE
                         // CLONE HEAT COOL
    uint arg;            // element id / temp amount
    uint chance;         // 0-10000
};
```

Symmetry (Sandboxels' flip/rotate) is expanded **CPU-side at upload**: author
one op with a symmetry tag (none / rotY4 / all-horizontal / full), the
uploader emits the expanded set. GPU stays branch-simple.

### 3.2 The pass pipeline (per tick)

Replaces the current hardcoded trio. Order mirrors Sandboxels' loop:

1. **Custom kernels** (Tier 4, optional) — codegen'd per-element GLSL, e.g.
   vine growth. Own `atomicCompSwap` claims, as today.
2. **Movement pass** (Tier 1) — one kernel, all voxels: look up
   `movement_class`, run the matching preset (powder: down + 4 diagonal-down
   w/ swap-through-lighter; liquid: down + direction-memory lateral, `flow`;
   gas: 6-dir walk w/ buoyancy vs. air density). Density-probability swaps as
   in Sandboxels rule 3. Claims via `atomicCompSwap` (unchanged pattern from
   `liquid.glsl`), losers persist themselves.
3. **Behavior-op pass** (Tier 3) — only elements with `behavior_count > 0`.
   Support-veto → swap → move1 → move2 priority, matching `pixelTick`.
4. **Reaction + thermal pass** (Tier 2) — proper ping-pong snapshot pass
   (see 3.3): per voxel, scan 6 neighbors in fixed order, first matching
   `ReactionRule` wins; apply `self_becomes` to *own cell only*. Then heat
   diffusion (average with neighbors, per-element conduct/insulate), then
   phase check (`temp_high/low` → `state_high/low`), then burn logic
   (spread, timer, burn_into) — all in one kernel, one aux write.
5. **Cleanup pass** — existing occupancy maintenance, unchanged.

Keep every kernel at the proven `8×8×8 = 512` local size — 1024-thread groups
silently no-op on macOS Metal (see project memory).

### 3.3 Parallel-correctness rules (the actually hard part)

- **Movement**: existing scheme is correct — destination claimed atomically in
  the write buffer, source vacated only on claim success. Keep it.
- **Reactions must not use in-place read-modify-write.** If thread A reads
  neighbor B mid-transmutation, the pair (A,B) decision desyncs and mass is
  duplicated or lost. Rule: the reaction pass reads a **stable snapshot**
  (post-movement buffer) and each thread writes **only its own cell** to the
  other buffer. Both sides of a reacting pair independently reach the *same*
  conclusion because:
  - the rule lookup is symmetric (A finds rule against B; B finds the mirror
    rule against A — the uploader materializes both halves from one authored
    rule), and
  - the "did it fire" roll uses **pair-symmetric RNG**:
    `hash(min(posA,posB), max(posA,posB), frame)` — both threads compute an
    identical random number, so either both transmute or neither does.
  - multi-neighbor conflicts: fixed neighbor scan order + first-match means a
    cell pairs with at most one neighbor per tick; a cell "spoken for" by an
    earlier neighbor in scan order simply wins that pairing on both threads.
- **Buffer parity**: passes 2–4 each need their own read/write flip. Replace
  raw `frame % 2` in the include with a `pass_parity` push constant the C++
  side increments per dispatched ping-pong pass (frame counter stays for RNG).
- **Aux buffer** follows the same parity as the voxel buffer so a moved voxel
  can carry its temperature with it (movement pass copies aux alongside data).

### 3.4 Godot-side classes (CPU)

Mirror the existing generator/edit-pass plumbing (`VoxelWorldRIDs::
add_voxel_buffers`, `upload_cellpond_rules()` shows the Resource→SSBO shape):

- **`VoxelElement : Resource`** — exported properties matching `ElementDef`,
  plus `Array[VoxelReaction] reactions`, `Array[VoxelBehaviorOp] behavior`,
  `String custom_glsl` (Tier 4).
- **`VoxelReaction : Resource`** — partner (by name), products, chance, temp
  gates, flags. Names resolve to ids at upload so sets are order-insensitive.
- **`VoxelElementSet : Resource`** — the dictionary. `add_element()`,
  `remove_element()`, `find_by_name()`; emits `changed`; serializes to
  `.tres` for authored sets.
- **`VoxelWorld`** — `set_element_set(set)`, and on `changed`:
  `_upload_element_tables()` (Tiers 1–3, sub-millisecond, safe every frame)
  and, only if any `custom_glsl` changed, `_rebuild_custom_pass()` (Tier 4,
  ~10s of ms, done between ticks). `gdcs` needs one small addition: a
  constructor taking shader *source* instead of a path (the compile call
  already takes source).

Runtime formulation then looks like:

```gdscript
var acid := VoxelElement.new()
acid.element_name = "acid"
acid.movement_class = VoxelElement.LIQUID
acid.density = 1100.0
acid.base_color = Color(0.62, 0.84, 0.16)
acid.emission = 0.4

var dissolve := VoxelReaction.new()
dissolve.partner = "solid"
dissolve.chance = 0.06
dissolve.self_becomes = ""        # keep
dissolve.partner_becomes = "air"  # corrode
acid.reactions.append(dissolve)

var quench := VoxelReaction.new()
quench.partner = "lava"
quench.chance = 1.0
quench.self_becomes = "steam"
quench.partner_becomes = "solid"
acid.reactions.append(quench)

world.get_element_set().add_element(acid)   # live next tick, no compile
```

Renderer integration: `getVoxelEmission` currently hardcodes lava — bind the
element table to the render shader too and read `emission`/glow per type, so
new elements light correctly without touching the raymarcher.

### 3.5 Phased implementation

1. **Element table + generic movement pass.** Port water/sand/lava to table
   entries; delete their hardcoded logic from `liquid.glsl`. Visual parity is
   the acceptance test. (Also: `pass_parity` push constant.)
2. **Aux buffer + reaction/thermal pass.** `freeze_lava.glsl` becomes one
   authored reaction rule (`lava + water → solid + steam`-style). Add
   temperature, phase transitions (ice/water/steam chain proves it), burning.
3. **Behavior-op pass + symmetry expansion.** Cloner, eraser, support, and
   simple growth become authorable. At this point arbitrary new CA are
   runtime-formulable as pure data.
4. **Tier 4 codegen.** Template that inlines `custom_glsl` snippets into a
   pass skeleton (helpers from `voxel_world.glsl.inc` available); port
   `vine_growth.glsl` into it as the reference example; hot-swap pipeline.
5. **Editor UI.** In-game element/reaction editor (the `rule_editor.gd`
   scene-switching pattern is a good host shell), save/load element sets as
   resources or JSON.

### 3.6 Performance notes

- Tables are tiny (element table 16 KB, realistic reaction sets a few KB) and
  read-only per dispatch — they'll sit in cache; the interpreter overhead is
  branchy but bounded (movement class switch + ≤ a handful of rules/voxel).
- Early-out on air + `movement_class == STATIC` keeps the movement pass at
  today's cost. Later win: indirect dispatch over non-empty bricks using the
  occupancy data that already exists.
- Reaction pass touches only voxels with `reaction_count > 0` neighbors of
  the right kind — cheap early-outs from the element table.
- Full pipeline is 3–4 dispatches over the grid vs. today's 4 — same order of
  magnitude; the win is that adding the *N*-th element costs zero dispatches.
