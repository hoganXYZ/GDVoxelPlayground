#ifndef VOXEL_ELEMENTS_GLSL
#define VOXEL_ELEMENTS_GLSL

// Data-driven cellular automata tables (see docs/runtime_ca_design.md).
// Only include this in shaders that get VoxelWorldRIDs::add_ca_buffers() bound.
// Requires voxel_world.glsl.inc and utility.glsl.inc to be included first.

// -------------------------------------- CONSTANTS --------------------------------------

const uint MOVE_STATIC = 0u;
const uint MOVE_POWDER = 1u;
const uint MOVE_LIQUID = 2u;
const uint MOVE_GAS    = 3u;
const uint MOVE_CUSTOM = 4u; // dynamic, but moved by a custom kernel (e.g. vine growth)

const uint ELEMENT_FLAG_DYNAMIC = 1u; // set at upload: element lives in one buffer only, cleanup erases it from prev

const uint ELEM_KEEP = 0xFFFFu;   // sentinel: reaction keeps the element unchanged
const uint ELEM_ANY  = 0xFFFFu;   // sentinel in op args: match any non-air element
const uint TEMP_NONE_HIGH = 0xFFFFFFFFu;
const uint TEMP_NONE_LOW  = 0u;

const uint REACTION_GATE_ON_PARTNER = 1u; // temp gates test the partner's temperature (mirror rules)

// Behavior op opcodes (Sandboxels 3x3 DSL, generalized to a 3D op list)
const uint OP_NONE    = 0u;
const uint OP_MOVE1   = 1u; // first-priority move into air
const uint OP_MOVE2   = 2u; // second-priority move into air
const uint OP_SWAP    = 3u; // swap with a dynamic occupant
const uint OP_SUPPORT = 4u; // if occupied (by arg element, or any), veto movement
const uint OP_CREATE  = 5u; // create arg element in empty cell
const uint OP_CHANGE  = 6u; // change occupant: arg = (from << 16) | to, from ELEM_ANY = any
const uint OP_DELETE  = 7u; // delete occupant (arg = element filter, ELEM_ANY = any)

// -------------------------------------- STRUCTS --------------------------------------

// must match GpuElementDef in voxel_element_set.h (80 bytes)
struct ElementDef {
    uint movement_class;
    float density;
    float flow;            // 0-1: chance per tick a liquid attempts lateral movement
    uint flags;
    uint temp_high_q;      // kelvin*16, TEMP_NONE_HIGH = disabled
    uint state_high;       // element id to become above temp_high
    uint temp_low_q;       // kelvin*16, TEMP_NONE_LOW = disabled
    uint state_low;
    uint life_init;        // 0 = immortal, else ticks until life_into
    uint life_into;        // element id (0 = air)
    uint initial_temp_q;
    float heat_conduct;    // 0-1, 0 = insulator
    uint reaction_offset;
    uint reaction_count;
    float emission;
    uint base_color16;
    uint behavior_offset;
    uint behavior_count;
    uint _pad0;
    uint _pad1;
};

// must match GpuReactionRule in voxel_element_set.h (32 bytes)
struct ReactionRule {
    uint partner;
    uint self_becomes;     // ELEM_KEEP = unchanged
    uint chance;           // 0-10000 per contact per tick
    uint temp_min_q;       // TEMP_NONE_LOW = no gate
    uint temp_max_q;       // TEMP_NONE_HIGH = no gate
    int  temp_delta_q;     // heat released (+) / absorbed (-) on fire
    uint flags;
    uint _pad;
};

// must match GpuBehaviorOp in voxel_element_set.h (16 bytes)
struct BehaviorOp {
    uint packed_offset;    // (x+1) | (y+1)<<2 | (z+1)<<4, each axis in -1..1
    uint opcode;
    uint arg;
    uint chance;           // 0-10000
};

layout(std430, set = 1, binding = 8) restrict readonly buffer ElementTable {
    ElementDef elementDefs[];
};

layout(std430, set = 1, binding = 9) restrict readonly buffer ReactionTable {
    ReactionRule reactionRules[];
};

layout(std430, set = 1, binding = 10) buffer VoxelAuxData {
    uint voxelAux[];
};

layout(std430, set = 1, binding = 11) buffer VoxelAuxData2 {
    uint voxelAux2[];
};

layout(std430, set = 1, binding = 12) restrict readonly buffer BehaviorOpTable {
    BehaviorOp behaviorOps[];
};

// -------------------------------------- AUX ACCESS --------------------------------------
// aux packing: bits 0-15 temperature (kelvin*16), bits 16-23 life counter, bits 24-31 flags

uint auxGetTempQ(uint aux) { return aux & 0xFFFFu; }
uint auxGetLife(uint aux) { return (aux >> 16) & 0xFFu; }
uint auxSetTempQ(uint aux, uint temp_q) { return (aux & 0xFFFF0000u) | min(temp_q, 0xFFFFu); }
uint auxSetLife(uint aux, uint life) { return (aux & 0xFF00FFFFu) | ((life & 0xFFu) << 16); }
uint makeAux(uint temp_q, uint life) { return (temp_q & 0xFFFFu) | ((life & 0xFFu) << 16); }

uint getPreviousAux(uint index) {
    return voxelWorldProperties.frame % 2 == 0 ? voxelAux2[index] : voxelAux[index];
}

uint getCurrentAux(uint index) {
    return voxelWorldProperties.frame % 2 == 0 ? voxelAux[index] : voxelAux2[index];
}

void setAux(uint index, uint aux) {
    if (voxelWorldProperties.frame % 2 == 0)
        voxelAux[index] = aux;
    else
        voxelAux2[index] = aux;
}

void setBothAux(uint index, uint aux) {
    voxelAux[index] = aux;
    voxelAux2[index] = aux;
}

// -------------------------------------- ELEMENT HELPERS --------------------------------------

bool isTypeDynamic(uint type) {
    return (elementDefs[type].flags & ELEMENT_FLAG_DYNAMIC) != 0u;
}

uint defaultAuxFor(uint type) {
    return makeAux(elementDefs[type].initial_temp_q, elementDefs[type].life_init);
}

// create a voxel of the given element with its base color, jittered per position
Voxel createElementVoxel(uint type, ivec3 pos) {
    vec3 base = decompress_color16(elementDefs[type].base_color16);
    return createVoxel(type, randomizedColor(base, pos));
}

// table-driven replacement for getVoxelEmission (which hardcodes lava)
float getElementEmission(Voxel voxel) {
    return elementDefs[getVoxelType(voxel)].emission;
}

// -------------------------------------- PAIR-SYMMETRIC RNG --------------------------------------
// Both cells of an interacting pair compute the same roll, so they agree on
// whether a reaction fired without any communication.

uint pairRoll10k(ivec3 a, ivec3 b, uint salt) {
    ivec3 lo = min(a, b);
    ivec3 hi = max(a, b);
    uvec4 h = hash(uvec4(uint(lo.x) ^ (uint(hi.x) << 10),
                         uint(lo.y) ^ (uint(hi.y) << 10),
                         uint(lo.z) ^ (uint(hi.z) << 10),
                         uint(voxelWorldProperties.frame) * 2654435761u + salt));
    return h.x % 10000u;
}

// single-cell roll, 0-9999
uint cellRoll10k(ivec3 p, uint salt) {
    uvec4 h = hash(uvec4(uvec3(p), uint(voxelWorldProperties.frame) * 747796405u + salt));
    return h.x % 10000u;
}

#endif // VOXEL_ELEMENTS_GLSL
