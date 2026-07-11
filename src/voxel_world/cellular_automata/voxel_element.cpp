#include "voxel_element.h"

using namespace godot;

// -------------------------------------- VoxelReaction --------------------------------------

void VoxelReaction::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("set_partner", "partner"), &VoxelReaction::set_partner);
    ClassDB::bind_method(D_METHOD("get_partner"), &VoxelReaction::get_partner);
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "partner"), "set_partner", "get_partner");

    ClassDB::bind_method(D_METHOD("set_self_becomes", "value"), &VoxelReaction::set_self_becomes);
    ClassDB::bind_method(D_METHOD("get_self_becomes"), &VoxelReaction::get_self_becomes);
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "self_becomes"), "set_self_becomes", "get_self_becomes");

    ClassDB::bind_method(D_METHOD("set_partner_becomes", "value"), &VoxelReaction::set_partner_becomes);
    ClassDB::bind_method(D_METHOD("get_partner_becomes"), &VoxelReaction::get_partner_becomes);
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "partner_becomes"), "set_partner_becomes", "get_partner_becomes");

    ClassDB::bind_method(D_METHOD("set_chance", "chance"), &VoxelReaction::set_chance);
    ClassDB::bind_method(D_METHOD("get_chance"), &VoxelReaction::get_chance);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "chance", PROPERTY_HINT_RANGE, "0,1,0.0001"), "set_chance", "get_chance");

    ClassDB::bind_method(D_METHOD("set_oneway", "oneway"), &VoxelReaction::set_oneway);
    ClassDB::bind_method(D_METHOD("get_oneway"), &VoxelReaction::get_oneway);
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "oneway"), "set_oneway", "get_oneway");

    ClassDB::bind_method(D_METHOD("set_temp_min", "kelvin"), &VoxelReaction::set_temp_min);
    ClassDB::bind_method(D_METHOD("get_temp_min"), &VoxelReaction::get_temp_min);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "temp_min"), "set_temp_min", "get_temp_min");

    ClassDB::bind_method(D_METHOD("set_temp_max", "kelvin"), &VoxelReaction::set_temp_max);
    ClassDB::bind_method(D_METHOD("get_temp_max"), &VoxelReaction::get_temp_max);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "temp_max"), "set_temp_max", "get_temp_max");

    ClassDB::bind_method(D_METHOD("set_temp_delta", "kelvin"), &VoxelReaction::set_temp_delta);
    ClassDB::bind_method(D_METHOD("get_temp_delta"), &VoxelReaction::get_temp_delta);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "temp_delta"), "set_temp_delta", "get_temp_delta");
}

// -------------------------------------- VoxelBehaviorOp --------------------------------------

void VoxelBehaviorOp::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("set_offset", "offset"), &VoxelBehaviorOp::set_offset);
    ClassDB::bind_method(D_METHOD("get_offset"), &VoxelBehaviorOp::get_offset);
    ADD_PROPERTY(PropertyInfo(Variant::VECTOR3I, "offset"), "set_offset", "get_offset");

    ClassDB::bind_method(D_METHOD("set_opcode", "opcode"), &VoxelBehaviorOp::set_opcode);
    ClassDB::bind_method(D_METHOD("get_opcode"), &VoxelBehaviorOp::get_opcode);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "opcode", PROPERTY_HINT_ENUM,
                              "None,Move1,Move2,Swap,Support,Create,Change,Delete"),
                 "set_opcode", "get_opcode");

    ClassDB::bind_method(D_METHOD("set_element_a", "element"), &VoxelBehaviorOp::set_element_a);
    ClassDB::bind_method(D_METHOD("get_element_a"), &VoxelBehaviorOp::get_element_a);
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "element_a"), "set_element_a", "get_element_a");

    ClassDB::bind_method(D_METHOD("set_element_b", "element"), &VoxelBehaviorOp::set_element_b);
    ClassDB::bind_method(D_METHOD("get_element_b"), &VoxelBehaviorOp::get_element_b);
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "element_b"), "set_element_b", "get_element_b");

    ClassDB::bind_method(D_METHOD("set_chance", "chance"), &VoxelBehaviorOp::set_chance);
    ClassDB::bind_method(D_METHOD("get_chance"), &VoxelBehaviorOp::get_chance);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "chance", PROPERTY_HINT_RANGE, "0,1,0.0001"), "set_chance", "get_chance");

    ClassDB::bind_method(D_METHOD("set_symmetry", "symmetry"), &VoxelBehaviorOp::set_symmetry);
    ClassDB::bind_method(D_METHOD("get_symmetry"), &VoxelBehaviorOp::get_symmetry);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "symmetry", PROPERTY_HINT_ENUM, "None,RotateY,All"),
                 "set_symmetry", "get_symmetry");

    BIND_CONSTANT(OP_NONE);
    BIND_CONSTANT(OP_MOVE1);
    BIND_CONSTANT(OP_MOVE2);
    BIND_CONSTANT(OP_SWAP);
    BIND_CONSTANT(OP_SUPPORT);
    BIND_CONSTANT(OP_CREATE);
    BIND_CONSTANT(OP_CHANGE);
    BIND_CONSTANT(OP_DELETE);
    BIND_CONSTANT(SYMMETRY_NONE);
    BIND_CONSTANT(SYMMETRY_ROTATE_Y);
    BIND_CONSTANT(SYMMETRY_ALL);
}

// -------------------------------------- VoxelElement --------------------------------------

Ref<VoxelReaction> VoxelElement::add_reaction(const String &p_partner, const String &p_self_becomes,
                                              const String &p_partner_becomes, float p_chance)
{
    Ref<VoxelReaction> r;
    r.instantiate();
    r->set_partner(p_partner);
    r->set_self_becomes(p_self_becomes);
    r->set_partner_becomes(p_partner_becomes);
    r->set_chance(p_chance);
    reactions.push_back(r);
    emit_changed();
    return r;
}

Ref<VoxelBehaviorOp> VoxelElement::add_behavior_op(int p_opcode, const Vector3i &p_offset, const String &p_element_a,
                                                   const String &p_element_b, float p_chance, int p_symmetry)
{
    Ref<VoxelBehaviorOp> op;
    op.instantiate();
    op->set_opcode(p_opcode);
    op->set_offset(p_offset);
    op->set_element_a(p_element_a);
    op->set_element_b(p_element_b);
    op->set_chance(p_chance);
    op->set_symmetry(p_symmetry);
    behavior.push_back(op);
    emit_changed();
    return op;
}

void VoxelElement::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("set_element_name", "name"), &VoxelElement::set_element_name);
    ClassDB::bind_method(D_METHOD("get_element_name"), &VoxelElement::get_element_name);
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "element_name"), "set_element_name", "get_element_name");

    ClassDB::bind_method(D_METHOD("set_movement_class", "movement_class"), &VoxelElement::set_movement_class);
    ClassDB::bind_method(D_METHOD("get_movement_class"), &VoxelElement::get_movement_class);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "movement_class", PROPERTY_HINT_ENUM, "Static,Powder,Liquid,Gas,Custom"),
                 "set_movement_class", "get_movement_class");

    ClassDB::bind_method(D_METHOD("set_density", "density"), &VoxelElement::set_density);
    ClassDB::bind_method(D_METHOD("get_density"), &VoxelElement::get_density);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "density"), "set_density", "get_density");

    ClassDB::bind_method(D_METHOD("set_flow", "flow"), &VoxelElement::set_flow);
    ClassDB::bind_method(D_METHOD("get_flow"), &VoxelElement::get_flow);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "flow", PROPERTY_HINT_RANGE, "0,1,0.001"), "set_flow", "get_flow");

    ClassDB::bind_method(D_METHOD("set_base_color", "color"), &VoxelElement::set_base_color);
    ClassDB::bind_method(D_METHOD("get_base_color"), &VoxelElement::get_base_color);
    ADD_PROPERTY(PropertyInfo(Variant::COLOR, "base_color"), "set_base_color", "get_base_color");

    ClassDB::bind_method(D_METHOD("set_emission", "emission"), &VoxelElement::set_emission);
    ClassDB::bind_method(D_METHOD("get_emission"), &VoxelElement::get_emission);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "emission"), "set_emission", "get_emission");

    ClassDB::bind_method(D_METHOD("set_initial_temp", "kelvin"), &VoxelElement::set_initial_temp);
    ClassDB::bind_method(D_METHOD("get_initial_temp"), &VoxelElement::get_initial_temp);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "initial_temp"), "set_initial_temp", "get_initial_temp");

    ClassDB::bind_method(D_METHOD("set_heat_conduct", "conduct"), &VoxelElement::set_heat_conduct);
    ClassDB::bind_method(D_METHOD("get_heat_conduct"), &VoxelElement::get_heat_conduct);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "heat_conduct", PROPERTY_HINT_RANGE, "0,1,0.001"),
                 "set_heat_conduct", "get_heat_conduct");

    ClassDB::bind_method(D_METHOD("set_temp_high", "kelvin"), &VoxelElement::set_temp_high);
    ClassDB::bind_method(D_METHOD("get_temp_high"), &VoxelElement::get_temp_high);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "temp_high"), "set_temp_high", "get_temp_high");

    ClassDB::bind_method(D_METHOD("set_state_high", "element"), &VoxelElement::set_state_high);
    ClassDB::bind_method(D_METHOD("get_state_high"), &VoxelElement::get_state_high);
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "state_high"), "set_state_high", "get_state_high");

    ClassDB::bind_method(D_METHOD("set_temp_low", "kelvin"), &VoxelElement::set_temp_low);
    ClassDB::bind_method(D_METHOD("get_temp_low"), &VoxelElement::get_temp_low);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "temp_low"), "set_temp_low", "get_temp_low");

    ClassDB::bind_method(D_METHOD("set_state_low", "element"), &VoxelElement::set_state_low);
    ClassDB::bind_method(D_METHOD("get_state_low"), &VoxelElement::get_state_low);
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "state_low"), "set_state_low", "get_state_low");

    ClassDB::bind_method(D_METHOD("set_life", "ticks"), &VoxelElement::set_life);
    ClassDB::bind_method(D_METHOD("get_life"), &VoxelElement::get_life);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "life", PROPERTY_HINT_RANGE, "0,255,1"), "set_life", "get_life");

    ClassDB::bind_method(D_METHOD("set_life_into", "element"), &VoxelElement::set_life_into);
    ClassDB::bind_method(D_METHOD("get_life_into"), &VoxelElement::get_life_into);
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "life_into"), "set_life_into", "get_life_into");

    ClassDB::bind_method(D_METHOD("set_reactions", "reactions"), &VoxelElement::set_reactions);
    ClassDB::bind_method(D_METHOD("get_reactions"), &VoxelElement::get_reactions);
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "reactions", PROPERTY_HINT_ARRAY_TYPE,
                              String::num_int64(Variant::OBJECT) + "/" +
                                  String::num_int64(PROPERTY_HINT_RESOURCE_TYPE) + ":VoxelReaction"),
                 "set_reactions", "get_reactions");

    ClassDB::bind_method(D_METHOD("set_behavior", "behavior"), &VoxelElement::set_behavior);
    ClassDB::bind_method(D_METHOD("get_behavior"), &VoxelElement::get_behavior);
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "behavior", PROPERTY_HINT_ARRAY_TYPE,
                              String::num_int64(Variant::OBJECT) + "/" +
                                  String::num_int64(PROPERTY_HINT_RESOURCE_TYPE) + ":VoxelBehaviorOp"),
                 "set_behavior", "get_behavior");

    ClassDB::bind_method(D_METHOD("add_reaction", "partner", "self_becomes", "partner_becomes", "chance"),
                         &VoxelElement::add_reaction);
    ClassDB::bind_method(
        D_METHOD("add_behavior_op", "opcode", "offset", "element_a", "element_b", "chance", "symmetry"),
        &VoxelElement::add_behavior_op);

    BIND_CONSTANT(MOVEMENT_STATIC);
    BIND_CONSTANT(MOVEMENT_POWDER);
    BIND_CONSTANT(MOVEMENT_LIQUID);
    BIND_CONSTANT(MOVEMENT_GAS);
    BIND_CONSTANT(MOVEMENT_CUSTOM);
}
