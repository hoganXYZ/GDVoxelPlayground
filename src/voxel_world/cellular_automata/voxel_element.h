#ifndef VOXEL_ELEMENT_H
#define VOXEL_ELEMENT_H

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/color.hpp>

namespace godot
{

// One entry of an element's pairwise reaction table (Sandboxels `reactions`).
// Fires when this element is face-adjacent to `partner`. Element references
// are by name; "" means "keep unchanged" and "air" means delete.
class VoxelReaction : public Resource
{
    GDCLASS(VoxelReaction, Resource);

protected:
    static void _bind_methods();

private:
    String partner;
    String self_becomes;    // "" = keep
    String partner_becomes; // "" = keep (enforced through a generated mirror rule)
    float chance = 1.0f;    // 0-1 per contact per tick
    bool oneway = false;    // do not generate the mirror rule
    float temp_min = 0.0f;  // kelvin gate on own temperature, 0 = disabled
    float temp_max = 0.0f;  // 0 = disabled
    float temp_delta = 0.0f; // kelvin added to self when the reaction fires

public:
    void set_partner(const String &v) { partner = v; }
    String get_partner() const { return partner; }
    void set_self_becomes(const String &v) { self_becomes = v; }
    String get_self_becomes() const { return self_becomes; }
    void set_partner_becomes(const String &v) { partner_becomes = v; }
    String get_partner_becomes() const { return partner_becomes; }
    void set_chance(float v) { chance = v; }
    float get_chance() const { return chance; }
    void set_oneway(bool v) { oneway = v; }
    bool get_oneway() const { return oneway; }
    void set_temp_min(float v) { temp_min = v; }
    float get_temp_min() const { return temp_min; }
    void set_temp_max(float v) { temp_max = v; }
    float get_temp_max() const { return temp_max; }
    void set_temp_delta(float v) { temp_delta = v; }
    float get_temp_delta() const { return temp_delta; }
};

// One neighborhood op of an element's behavior program (Sandboxels' 3x3 grid
// DSL generalized to 3D). When an element has any ops, they replace its
// movement-class preset.
class VoxelBehaviorOp : public Resource
{
    GDCLASS(VoxelBehaviorOp, Resource);

protected:
    static void _bind_methods();

private:
    Vector3i offset;      // -1..1 per axis
    int opcode = 0;
    String element_a;     // CREATE: element to create; CHANGE: from-filter ("" = any);
                          // DELETE/SWAP/SUPPORT: filter ("" = any)
    String element_b;     // CHANGE: element to become
    float chance = 1.0f;  // 0-1 per tick
    int symmetry = 0;

public:
    // must match the OP_* constants in voxel_elements.glsl.inc
    static const int OP_NONE = 0;
    static const int OP_MOVE1 = 1;
    static const int OP_MOVE2 = 2;
    static const int OP_SWAP = 3;
    static const int OP_SUPPORT = 4;
    static const int OP_CREATE = 5;
    static const int OP_CHANGE = 6;
    static const int OP_DELETE = 7;

    static const int SYMMETRY_NONE = 0;      // just the authored offset
    static const int SYMMETRY_ROTATE_Y = 1;  // 4 rotations around Y
    static const int SYMMETRY_ALL = 2;       // all signed axis permutations

    void set_offset(const Vector3i &v) { offset = v; }
    Vector3i get_offset() const { return offset; }
    void set_opcode(int v) { opcode = v; }
    int get_opcode() const { return opcode; }
    void set_element_a(const String &v) { element_a = v; }
    String get_element_a() const { return element_a; }
    void set_element_b(const String &v) { element_b = v; }
    String get_element_b() const { return element_b; }
    void set_chance(float v) { chance = v; }
    float get_chance() const { return chance; }
    void set_symmetry(int v) { symmetry = v; }
    int get_symmetry() const { return symmetry; }
};

// A material definition: everything the GPU passes need to know about one
// element id. Collected into a VoxelElementSet (index in the set = element id).
class VoxelElement : public Resource
{
    GDCLASS(VoxelElement, Resource);

protected:
    static void _bind_methods();

private:
    String element_name;
    int movement_class = 0;
    float density = 1000.0f;      // kg/m^3-ish, drives sink/float swaps
    float flow = 1.0f;            // liquids: chance per tick to attempt lateral flow
    Color base_color = Color(0.5f, 0.5f, 0.5f);
    float emission = 0.0f;
    float initial_temp = 293.0f;  // kelvin, applied when painted/created by rules
    float heat_conduct = 0.3f;    // 0-1, 0 = perfect insulator
    float temp_high = 0.0f;       // kelvin, 0 = disabled
    String state_high;            // element to become above temp_high
    float temp_low = 0.0f;        // kelvin, 0 = disabled
    String state_low;
    int life = 0;                 // ticks until life_into, 0 = immortal
    String life_into;             // "" = air
    Array reactions;              // VoxelReaction resources
    Array behavior;               // VoxelBehaviorOp resources

public:
    // must match MOVE_* in voxel_elements.glsl.inc
    static const int MOVEMENT_STATIC = 0;
    static const int MOVEMENT_POWDER = 1;
    static const int MOVEMENT_LIQUID = 2;
    static const int MOVEMENT_GAS = 3;
    static const int MOVEMENT_CUSTOM = 4;

    void set_element_name(const String &v) { element_name = v; }
    String get_element_name() const { return element_name; }
    void set_movement_class(int v) { movement_class = v; }
    int get_movement_class() const { return movement_class; }
    void set_density(float v) { density = v; }
    float get_density() const { return density; }
    void set_flow(float v) { flow = v; }
    float get_flow() const { return flow; }
    void set_base_color(const Color &v) { base_color = v; }
    Color get_base_color() const { return base_color; }
    void set_emission(float v) { emission = v; }
    float get_emission() const { return emission; }
    void set_initial_temp(float v) { initial_temp = v; }
    float get_initial_temp() const { return initial_temp; }
    void set_heat_conduct(float v) { heat_conduct = v; }
    float get_heat_conduct() const { return heat_conduct; }
    void set_temp_high(float v) { temp_high = v; }
    float get_temp_high() const { return temp_high; }
    void set_state_high(const String &v) { state_high = v; }
    String get_state_high() const { return state_high; }
    void set_temp_low(float v) { temp_low = v; }
    float get_temp_low() const { return temp_low; }
    void set_state_low(const String &v) { state_low = v; }
    String get_state_low() const { return state_low; }
    void set_life(int v) { life = v; }
    int get_life() const { return life; }
    void set_life_into(const String &v) { life_into = v; }
    String get_life_into() const { return life_into; }
    void set_reactions(const Array &v) { reactions = v; }
    Array get_reactions() const { return reactions; }
    void set_behavior(const Array &v) { behavior = v; }
    Array get_behavior() const { return behavior; }

    // convenience for building sets from script
    Ref<VoxelReaction> add_reaction(const String &p_partner, const String &p_self_becomes,
                                    const String &p_partner_becomes, float p_chance);
    Ref<VoxelBehaviorOp> add_behavior_op(int p_opcode, const Vector3i &p_offset, const String &p_element_a,
                                         const String &p_element_b, float p_chance, int p_symmetry);
};

} // namespace godot

#endif // VOXEL_ELEMENT_H
