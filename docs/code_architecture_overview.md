# Real-Time Squad Game Architecture Patterns

A directive guide for structuring the codebase of an ant-colony / swarm-RTS game — a real-time game where the player commands groups of semi-autonomous units that also exhibit emergent self-organizing behavior via indirect communication. Adapted from Bob Nystrom's architectural approach in *Game Programming Patterns*.

---

## Core Philosophy

- **Be intentional about ECS.** A real-time game with rendering, physics, and AI does have meaningful engine domains, so a traditional domain-split ECS may earn its keep for the rendering and simulation layer. However, **gameplay logic** (what units *can do*, how orders work, what distinguishes unit types) benefits from a different decomposition — split along **capabilities and commands**, not engine subsystems.
- **Reify types and orders into first-class objects.** The general heuristic: when the code feels stuck or rigid, take a **verb** in the program and turn it into a **noun** — an object you can create, queue, inspect, cancel, and extend.
- **Design for scale.** A Pikmin-style game may have 100 units on screen simultaneously; an RTS may have thousands. Patterns must support large homogeneous groups cheaply, not just individual special-case entities.

---

## Pattern 1 — Capability Components (Composition over Inheritance)

### Problem

A `Unit` class accumulates every possible behavior — melee attack, ranged attack, carrying resources, building structures, swimming, flying, burrowing, healing allies — into one sprawling type. Inheritance hierarchies ("Unit → CombatUnit → MeleeUnit") break down the moment you want a unit that can both fight and carry, or a builder that can also repair.

In a Pikmin-like game this is especially acute: Red Pikmin fight and resist fire; Blue Pikmin swim; Yellow Pikmin are thrown higher and resist electricity; Purples are heavy and strong. These are overlapping capability sets, not a clean tree.

### Solution

Extract each **capability** a unit can have into its own small class, stored as an optional field (or collected in a list) on the unit.

```
Unit
 ├── combat: CombatCapability?       # can deal/receive damage
 ├── carrier: CarrierCapability?     # can pick up and transport objects
 ├── builder: BuilderCapability?     # can construct or repair structures
 ├── traversal: TraversalCapability? # swim, fly, burrow, climb
 ├── hazardResist: Set<HazardType>   # fire, water, electricity, poison...
 ├── special: SpecialAbility?        # unique activated ability
 └── ...other capabilities
```

- Each capability class is focused and self-contained. `CombatCapability` holds attack damage, attack speed, range, and the logic for resolving a hit. `CarrierCapability` holds carry strength and attachment-point logic.
- `TraversalCapability` can use a shallow-but-wide inheritance tree (swim, fly, burrow) since the variants are mutually exclusive within the capability. Shallow + wide hierarchies are where inheritance shines.
- Units become freely composable bags of capabilities — easy to define in data files and construct procedurally. A new unit type is just a new combination of existing capabilities with tweaked parameters.

### When to Apply

Use this pattern for any entity that has a **mix-and-match set of optional behaviors**: units, structures (some produce units, some research, some defend), resource nodes, projectiles, environmental hazards.

### Rules

1. Identify the distinct capabilities the entity type can have.
2. Create a class (or struct/record) for each capability.
3. Store each as an optional/nullable field on the parent entity. If a unit might have multiple instances of a capability type (e.g., multiple resistances), use a collection.
4. Prefer composition. Resort to inheritance only within a single capability where the hierarchy is shallow (one level deep) and wide (many sibling variants).
5. Capabilities may hold their own per-instance state (cooldown timers, carry targets, build progress). Keep that state on the capability, not on the unit.

---

## Pattern 2 — Type Object (Unit Blueprint / Archetype)

### Problem

You have dozens of unit types. Every Red Pikmin shares the same base stats, visual appearance, capability set, and default AI priorities. Duplicating that data across 50 Red Pikmin instances is wasteful and messy. Hardcoding each unit type as a subclass is rigid and cannot be driven by data files or modding.

### Solution

Define a **Type Object** class (e.g., `UnitBlueprint` or `UnitType`) that holds everything shared by a kind of unit. Each unit instance holds a reference to its blueprint.

```
UnitBlueprint ("red_pikmin")
 ├── name, sprite/model, animations
 ├── base stats (maxHealth, speed, attackDamage, carryStrength, ...)
 ├── default capabilities (combat: yes, carrier: yes, hazardResist: [fire])
 ├── AI priority hints (combat weight: high, gather weight: medium, ...)
 └── parent: UnitBlueprint?     # optional prototype-chain inheritance

Unit (instance)
 ├── blueprint → UnitBlueprint ("red_pikmin")
 ├── currentHealth
 ├── position, velocity
 ├── currentOrder: Order?
 ├── ...per-instance mutable state
 └── capabilities (instantiated from blueprint defaults, can be modified at runtime)
```

- This is a **meta-class at the application level**: `UnitBlueprint` is a class whose instances each represent a class of unit.
- Because you control the semantics, you can support prototype-style inheritance — e.g., a "flower red pikmin" blueprint inherits from "red pikmin" and overrides only speed and attack damage.
- Easily loaded from data files (JSON, YAML, etc.), enabling designers to create new unit types or modders to add content without code changes.
- For an RTS, this same pattern covers building types, upgrade definitions, tech tree nodes, and resource types.

### When to Apply

Any time you have many runtime instances that fall into a set of **named types sharing default data**: unit types, structure types, projectile types, terrain types, upgrade definitions, status effect definitions.

### Rules

1. Identify which fields are shared across all instances of a "kind" and which are per-instance mutable state.
2. Create a Type Object class holding the shared fields. Instantiate it once per kind.
3. Each instance holds a reference to its Type Object.
4. At spawn time, use the blueprint to instantiate the unit's capabilities with the correct default parameters. Allow per-instance modification afterward (buffs, upgrades, damage).
5. Optionally support a `parent` pointer on the Type Object for data-driven inheritance.

---

## Pattern 3 — Order / Command (Reified Commands)

### Problem

Your `Unit` class is accumulating all behavioral code — moving to a position, attacking a target, carrying a resource back to base, building a structure, idling, fleeing from hazards. The class grows into thousands of lines. Meanwhile, you need player-issued commands and autonomous AI decisions to produce the same behaviors. You also need to queue, cancel, and interrupt orders gracefully in real time.

### Solution

Reify each **order** (or command) as an **Order object** (the Gang of Four "Command" pattern, adapted for real-time).

Unlike a turn-based game where an action executes in a single discrete step, an RTS order is **long-running** — it persists across many frames and progresses through internal states until it completes, fails, or is interrupted.

```
Order (base)
 ├── start(unit, game)                         # called once when the order begins
 ├── update(unit, game, deltaTime) → Status    # called every frame; returns Running / Succeeded / Failed
 ├── cancel(unit, game)                        # called when interrupted or replaced
 └── ...

MoveOrder           # pathfind to a position, update movement each frame
AttackOrder         # approach target, enter attack range, deal damage on cooldown
GatherOrder         # move to resource, pick up, carry to base, deposit, repeat
BuildOrder          # move to build site, play build animation, increment build progress
FollowOrder         # stay within range of a leader; reposition each frame
IdleOrder           # wander, wait for reassignment
ReturnResourceOrder # carry a held resource back to the nearest depot
```

**Game loop pseudocode:**

```
each frame (deltaTime):
    for each unit:
        if unit.currentOrder is null:
            unit.currentOrder = unit.ai.chooseOrder(unit, gameState)

        status = unit.currentOrder.update(unit, gameState, deltaTime)

        if status == Succeeded or status == Failed:
            unit.currentOrder = null   # AI will assign a new order next frame
```

**Player input:**

```
on player command (selectedUnits, targetPosition, targetEntity):
    for each unit in selectedUnits:
        order = resolveOrder(unit, targetPosition, targetEntity)
        unit.currentOrder.cancel(unit, gameState)
        unit.currentOrder = order
        order.start(unit, gameState)
```

### Why This Works

1. **Pulls code out of Unit.** Each order is its own class. Unit becomes a lean data holder. Adding new behaviors (e.g., a "dance" emote, a "patrol" loop) means adding new Order subclasses, not inflating the Unit class.
2. **Abstraction layer between decision and execution.** The player issues orders by constructing Order objects. The unit AI issues orders by constructing the *same* Order objects. Behavioral code is written once and shared — an AI-initiated `GatherOrder` and a player-issued `GatherOrder` execute identically.
3. **Supports real-time lifecycle.** Orders have `start`, `update`, and `cancel` hooks. They can track internal progress (pathfinding state, attack cooldown timers, carry state) as their own fields, keeping Unit clean.
4. **Queueable and composable.** Maintain an order queue per unit. Shift-click to append. Orders can spawn sub-orders (a `GatherOrder` internally issues a `MoveOrder` to reach the resource, then a `ReturnResourceOrder` to bring it back).
5. **Enables replay, networking, and debugging.** Since every command is a serializable object with a timestamp, you can log them for replay, send them over the network for multiplayer sync, or display them in a debug overlay.

### Compound Orders and Sub-Orders

Complex behaviors are composed from simpler orders. A `GatherOrder` might internally cycle through: `MoveOrder(resource) → PickUpAction → MoveOrder(depot) → DepositAction → repeat`. Implement this as a state machine inside the compound order, or as an order that pushes sub-orders onto a per-unit order stack.

```
GatherOrder
 ├── state: MovingToResource | PickingUp | ReturningToDepot | Depositing
 ├── targetResource
 ├── update():
 │     switch state:
 │       MovingToResource → pathfind toward resource; on arrival → PickingUp
 │       PickingUp → play animation; attach resource; → ReturningToDepot
 │       ReturningToDepot → pathfind toward depot; on arrival → Depositing
 │       Depositing → add resource to stockpile; → MovingToResource (loop)
 └── cancel(): drop carried resource if any
```

### When to Apply

- Any real-time game where units execute long-running tasks.
- Any time you need to decouple "deciding what to do" from "doing it."
- Any time player commands and AI decisions should share the same behavioral code.
- Multiplayer RTS (lockstep or command-streaming architectures).

### Rules

1. Define a base `Order` class with `start`, `update(deltaTime) → Status`, and `cancel` methods.
2. Create a subclass for every distinct thing a unit can be told to do.
3. A unit's only behavioral job is to **hold and yield to** its current order — not to contain the order logic itself.
4. The game loop is responsible for ticking each unit's current order every frame.
5. Player input and AI both produce the same Order types — never duplicate behavioral logic between them.
6. Complex multi-step behaviors should be compound orders that internally sequence simpler sub-orders, not monolithic procedural code.

---

## Pattern 4 — Group / Squad Coordination

### Problem

In a Pikmin-like or RTS game, the player almost never commands a single unit. They command groups — "send these 20 Pikmin to attack that boss," "rally all idle workers to this resource patch." If every unit independently pathfinds and makes decisions, you get chaotic, inefficient mob behavior and waste CPU on redundant calculations.

### Solution

Introduce a **Squad** or **Group** object that sits between the player/AI commander and the individual units.

```
Squad
 ├── members: List<Unit>
 ├── formation: FormationType?       # cluster, line, surround, etc.
 ├── sharedOrder: Order?             # the group-level objective
 ├── assignRoles()                   # distribute sub-tasks among members
 └── update(deltaTime)               # coordinate members each frame

Example — player throws 20 Pikmin at a large creature:
  Squad.sharedOrder = AttackOrder(target: creature)
  Squad.assignRoles():
    10 melee Pikmin → flank and latch on
    5 ranged Pikmin → maintain distance and throw projectiles
    5 carrier Pikmin → wait until creature is dead, then carry the corpse
```

- The squad handles pathfinding at the group level (one pathfind call, not 20), then assigns individual offsets or sub-orders per unit.
- Formation logic lives on the squad, not on individual units.
- The squad can mediate task assignment — when a resource node is depleted, the squad reassigns its members, rather than each unit independently re-evaluating.

### When to Apply

- Any time the player commands multiple units at once.
- Any time units need coordinated behavior (formations, flanking, task division, carry-weight pooling).
- Pikmin-style "swarm" games where the group is the primary unit of control.

### Rules

1. Create a Squad/Group class that owns a list of member units.
2. Player commands target squads, not individual units. The squad decomposes the group-level order into per-unit sub-orders.
3. Shared computation (group pathfinding, threat assessment) happens once at the squad level.
4. Individual units still hold their own Order and update independently — the squad coordinates what orders they receive, not how they execute them.
5. Units may move between squads dynamically (split, merge, reassign).

---

## Pattern 5 — Pheromone Field (Stigmergic Communication)

### Problem

Direct commands (Pattern 3 and 4) work well when the player is actively managing units, but ants don't wait for orders — they react to their environment. You want units to exhibit emergent, self-organizing behavior: ants find food, lay a trail, and other ants follow that trail without anyone issuing an explicit "go here" command. This creates the feeling of a living colony rather than a remote-controlled army.

At the same time, this ambient behavior needs to **coexist** with direct Pikmin-style commands. The player should be able to grab 30 ants and throw them at an enemy (direct order), while 200 other ants autonomously forage along pheromone trails in the background.

### Solution

Introduce a **Pheromone Field** — a spatial data layer that units write to and read from. Pheromones are the indirect communication channel. Units deposit pheromones as a side effect of their actions, and idle units sense nearby pheromones to decide what to do autonomously.

#### The Field

The pheromone field is a grid (or set of grids) aligned with your game world. Each cell stores a floating-point intensity value per pheromone type.

```
PheromoneField
 ├── grid: float[width][height]        # intensity at each cell
 ├── type: PheromoneType               # what this layer represents
 ├── decayRate: float                  # how fast intensity fades per second
 ├── diffusionRate: float              # how fast intensity spreads to neighbors
 │
 ├── deposit(position, amount)         # ant drops pheromone here
 ├── sample(position) → float          # read intensity at a point
 ├── sampleGradient(position) → Vec2   # direction of increasing intensity
 └── update(deltaTime)                 # decay and diffuse all cells

One PheromoneField instance per PheromoneType:
  PheromoneType.FOOD_TRAIL       # "I found food, follow me home"
  PheromoneType.HOME_TRAIL       # "I'm heading home, follow me to the nest"
  PheromoneType.DANGER           # "threat detected here, avoid or rally"
  PheromoneType.RECRUITMENT      # "help needed here — carry task, dig task"
  PheromoneType.TERRITORY        # "this area is claimed / patrolled"
  ...extensible via data
```

#### Deposit Rules (Writing)

Units deposit pheromones as a **side effect** of executing their current Order. This keeps pheromone logic decoupled from the order itself — the order doesn't need to know about pheromones.

```
PheromoneEmitter (capability component on the unit)
 ├── emissionRules: List<EmissionRule>
 └── update(unit, fields, deltaTime):
       for each rule in emissionRules:
           if rule.condition(unit):
               fields[rule.type].deposit(unit.position, rule.amount * deltaTime)

EmissionRule
 ├── type: PheromoneType
 ├── amount: float                     # intensity per second
 └── condition: (Unit) → bool          # when to emit

Example rules:
  - Emit FOOD_TRAIL while carrying food (condition: unit.isCarrying && unit.cargo.type == Food)
  - Emit HOME_TRAIL while walking toward the nest without food (condition: !unit.isCarrying && unit.currentOrder is MoveOrder toward nest)
  - Emit DANGER at high intensity when taking damage (condition: unit.wasDamagedThisFrame)
  - Emit RECRUITMENT when standing near a task that needs more workers (condition: unit.currentOrder is GatherOrder && resource.remainingCarrySlots > 0)
```

This is a **Capability Component** (Pattern 1) — not every unit needs to emit pheromones, and different unit types may have different emission rules loaded from their Blueprint (Pattern 2).

#### Sensing Rules (Reading)

Idle or autonomously-behaving units sense the pheromone field to decide what to do. This is handled by a **Pheromone Sensor** capability that feeds into the unit's AI decision-making.

```
PheromoneSensor (capability component on the unit)
 ├── sensitivities: Map<PheromoneType, float>   # how strongly this unit responds to each type
 ├── senseRadius: float
 │
 └── evaluate(unit, fields) → PheromoneSignal?
       # sample each field the unit is sensitive to
       # return the strongest signal (type + gradient direction + intensity)
       # or null if nothing interesting is nearby
```

The unit's AI consults the sensor when it has no direct order:

```
Unit AI decision flow:
  1. If unit has a direct player-issued Order → execute it (Pattern 3). Done.
  2. If unit belongs to a Squad with a sharedOrder → execute squad-assigned sub-order (Pattern 4). Done.
  3. Query PheromoneSensor:
     a. FOOD_TRAIL detected → create FollowTrailOrder(FOOD_TRAIL) — walk up the gradient toward food
     b. DANGER detected → create FleeOrder(away from gradient) or RallyOrder(toward gradient), depending on unit type
     c. RECRUITMENT detected → create MoveOrder(toward signal) then volunteer for the task
     d. Nothing detected → IdleOrder (wander randomly, scout)
```

#### The Priority Stack: Direct Orders > Squad Orders > Pheromone Response > Idle

This is the critical integration point. Pheromones do **not** compete with direct commands — they fill the gap when no explicit command exists. The priority is:

```
1. Direct player Order (player threw/commanded this specific unit)    ← highest
2. Squad-assigned sub-order (unit belongs to a player-managed group)
3. Pheromone-driven autonomous Order (unit senses trails and self-assigns)
4. Idle / wander                                                      ← lowest
```

When a direct order completes or is cancelled, the unit drops back to pheromone sensing. When the player grabs an ant off a trail and throws it at an enemy, the direct order takes over immediately; when that fight ends, the ant picks up the nearest pheromone trail and resumes autonomous behavior.

#### Decay, Diffusion, and Emergent Behavior

Pheromones are not static waypoints — they are a living, decaying signal. This is what creates emergent intelligence:

- **Decay**: Every pheromone cell loses intensity each frame (`intensity -= decayRate * deltaTime`). A trail that is no longer reinforced by ants walking it will fade and disappear. This means ants naturally stop following a trail to a depleted food source — the trail simply evaporates because no one is depositing on it anymore.
- **Diffusion**: Each frame, intensity spreads slightly to neighboring cells. This widens trails so they're easier to detect, and creates smooth gradients that units can follow. Tune diffusion rate low to keep trails narrow and precise, or high for broad area-of-effect signals like DANGER.
- **Reinforcement**: When many ants walk the same path, their overlapping deposits create a stronger signal. The busiest, most productive trails self-amplify. Less-used trails fade. This is automatic optimization with no central planner.

```
PheromoneField.update(deltaTime):
    for each cell (x, y):
        # Decay
        grid[x][y] *= (1.0 - decayRate * deltaTime)

        # Diffusion (simple 4-neighbor average blend)
        avg = average of grid[x±1][y±1] neighbors
        grid[x][y] = lerp(grid[x][y], avg, diffusionRate * deltaTime)

        # Clamp
        grid[x][y] = clamp(grid[x][y], 0, maxIntensity)
```

#### Player Interaction with Pheromones

The pheromone system can also be a **player tool**, not just an autonomous AI mechanism:

- **Player-placed pheromones**: The player can paint RECRUITMENT or FOOD_TRAIL pheromones directly onto the map to guide idle ants toward an area without selecting individual units. This is a softer, more ant-thematic alternative to direct commands.
- **Pheromone suppression**: The player can erase or block pheromone trails to redirect traffic — e.g., cutting off a trail that leads through a dangerous area.
- **Trail visualization**: Render pheromone fields as a toggleable overlay so the player can see the colony's communication network. This is powerful for debugging during development and becomes a strategic UI element in the final game.

### When to Apply

- Any game where units should exhibit autonomous, self-organizing behavior without explicit commands.
- Ant, insect, or swarm-themed games where indirect communication is thematically central.
- Any game where you want a spectrum from full player control to full autonomy — pheromones fill the "no one told me what to do" gap.
- Games with resource logistics chains where you want traffic to self-optimize (busy routes get stronger trails, depleted routes fade).

### Rules

1. **The pheromone field is a separate spatial data structure** — not stored on units, not stored on tiles. It is its own system, updated once per frame globally.
2. **One field per pheromone type.** Don't mix signal types in the same grid. This keeps sampling and decay tuning independent.
3. **Units write pheromones via an Emitter capability component** with data-driven emission rules. The Order being executed does not need to know about pheromones — the emitter reacts to unit state.
4. **Units read pheromones via a Sensor capability component** that feeds into AI decision-making. Sensing produces a candidate Order (Pattern 3), which enters the priority stack below direct and squad orders.
5. **Direct orders always win.** Pheromone-driven behavior is the fallback for uncommanded units. When a direct order ends, the unit returns to pheromone sensing. Never let trail-following override an explicit player command.
6. **Decay is mandatory.** Without decay, trails become permanent noise. Tune decay rate so trails last long enough to be useful but short enough to respond to changing conditions (food depleted, threat gone).
7. **Keep pheromone update cheap.** You are updating every cell every frame. Use a flat array, not a hash map. Consider updating in chunks or at a lower tick rate (e.g., 10Hz) if the grid is large. Profile early.
8. **Expose pheromones as a player tool.** Let the player paint, erase, and visualize trails. This bridges the gap between direct micro-control and hands-off colony management.

---

## How the Patterns Interact — The Full Decision Pipeline

For an ant-colony game, the five patterns compose into a clean pipeline:

```
UnitBlueprint (Pattern 2)
 └── spawns → Unit with capabilities (Pattern 1)
                ├── PheromoneEmitter capability
                ├── PheromoneSensor capability
                ├── CombatCapability, CarrierCapability, etc.
                │
                └── Each frame, the unit needs an Order (Pattern 3):
                     │
                     ├─ Priority 1: Direct player Order?        → execute it
                     ├─ Priority 2: Squad-assigned sub-order?   → execute it (Pattern 4)
                     ├─ Priority 3: PheromoneSensor signal?     → create and execute autonomous Order
                     └─ Priority 4: nothing                     → IdleOrder (wander/scout)
                     │
                     While executing, PheromoneEmitter deposits trails (Pattern 5)
                     based on what the unit is doing and carrying.

PheromoneField (Pattern 5)
 └── updated globally each frame: decay, diffuse, clamp
     read by sensors, written by emitters, paintable by player
```

---

## Summary Checklist

When structuring an ant-colony or swarm-RTS codebase, apply these patterns in combination:

- [ ] **Capability Components** — Split units along what they *can do* (fight, carry, build, swim, emit pheromones, sense pheromones), not along engine subsystems. Compose freely; inherit shallowly.
- [ ] **Type Objects (Blueprints)** — Separate per-type shared data from per-instance mutable state. One blueprint per unit kind, referenced by all instances. Data-driven and moddable.
- [ ] **Order Commands** — Reify every unit command as a long-running object with `start`/`update`/`cancel`. Keep units lean. Player input, AI, and pheromone responses all produce the same Order types.
- [ ] **Squad Coordination** — Group units under a squad object that mediates between player commands and individual unit orders. Shared computation happens once at the group level.
- [ ] **Pheromone Fields** — A spatial data layer for indirect communication. Units deposit trails as a side effect of their actions; idle units sense trails to self-assign orders. Decays and diffuses each frame. Coexists with direct commands via a clear priority stack. Doubles as a player tool for soft colony guidance.
- [ ] **General heuristic** — When the code feels stuck or rigid, find a verb and turn it into a noun. Making operations first-class unlocks flexibility.