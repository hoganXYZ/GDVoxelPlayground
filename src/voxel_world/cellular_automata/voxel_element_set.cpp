#include "voxel_element_set.h"
#include "utils.h"
#include <godot_cpp/variant/utility_functions.hpp>
#include <vector>

using namespace godot;

// -------------------------------------- helpers --------------------------------------

void VoxelElementSet::set_elements(const Array &v)
{
    elements = v;
    emit_changed();
}

int VoxelElementSet::add_element(const Ref<VoxelElement> &element)
{
    ERR_FAIL_COND_V(element.is_null(), -1);
    if (elements.size() >= MAX_ELEMENTS)
    {
        UtilityFunctions::printerr("VoxelElementSet: element limit (256) reached.");
        return -1;
    }
    int existing = find_element_id(element->get_element_name());
    if (existing >= 0)
    {
        elements[existing] = element;
        emit_changed();
        return existing;
    }
    elements.push_back(element);
    emit_changed();
    return elements.size() - 1;
}

int VoxelElementSet::find_element_id(const String &name) const
{
    if (name.is_empty())
        return -1;
    for (int i = 0; i < elements.size(); i++)
    {
        Ref<VoxelElement> e = elements[i];
        if (e.is_valid() && e->get_element_name() == name)
            return i;
    }
    return -1;
}

Ref<VoxelElement> VoxelElementSet::get_element(int id) const
{
    if (id < 0 || id >= elements.size())
        return Ref<VoxelElement>();
    return elements[id];
}

Ref<VoxelElement> VoxelElementSet::get_element_by_name(const String &name) const
{
    return get_element(find_element_id(name));
}

// resolve an element name to an id; "" resolves to p_fallback
static uint32_t resolve_name(const VoxelElementSet *set, const String &name, uint32_t p_fallback,
                             const String &context)
{
    if (name.is_empty())
        return p_fallback;
    int id = set->find_element_id(name);
    if (id < 0)
    {
        UtilityFunctions::printerr("VoxelElementSet: unknown element '", name, "' referenced by ", context);
        return p_fallback;
    }
    return (uint32_t)id;
}

static uint32_t pack_op_offset(Vector3i off)
{
    off = off.clamp(Vector3i(-1, -1, -1), Vector3i(1, 1, 1));
    return uint32_t(off.x + 1) | (uint32_t(off.y + 1) << 2) | (uint32_t(off.z + 1) << 4);
}

static void expand_symmetry(const Vector3i &off, int symmetry, std::vector<Vector3i> &out)
{
    out.clear();
    auto push_unique = [&out](Vector3i v) {
        for (const Vector3i &e : out)
            if (e == v)
                return;
        out.push_back(v);
    };

    switch (symmetry)
    {
    case VoxelBehaviorOp::SYMMETRY_ROTATE_Y:
        push_unique(off);
        push_unique(Vector3i(off.z, off.y, -off.x));
        push_unique(Vector3i(-off.x, off.y, -off.z));
        push_unique(Vector3i(-off.z, off.y, off.x));
        break;
    case VoxelBehaviorOp::SYMMETRY_ALL: {
        const int p[6][3] = {{0, 1, 2}, {0, 2, 1}, {1, 0, 2}, {1, 2, 0}, {2, 0, 1}, {2, 1, 0}};
        int c[3] = {off.x, off.y, off.z};
        for (int i = 0; i < 6; i++)
            for (int sx = -1; sx <= 1; sx += 2)
                for (int sy = -1; sy <= 1; sy += 2)
                    for (int sz = -1; sz <= 1; sz += 2)
                        push_unique(Vector3i(sx * c[p[i][0]], sy * c[p[i][1]], sz * c[p[i][2]]));
        break;
    }
    default:
        push_unique(off);
        break;
    }
}

// -------------------------------------- table builder --------------------------------------

bool VoxelElementSet::build_tables(PackedByteArray &r_element_table, PackedByteArray &r_reaction_table,
                                   PackedByteArray &r_behavior_table) const
{
    const int count = MIN((int)elements.size(), MAX_ELEMENTS);
    if ((int)elements.size() > MAX_ELEMENTS)
        UtilityFunctions::printerr("VoxelElementSet: more than 256 elements; extras ignored.");

    std::vector<GpuElementDef> defs(MAX_ELEMENTS);
    std::vector<std::vector<GpuReactionRule>> rules_per(count);
    std::vector<std::vector<GpuBehaviorOp>> ops_per(count);

    // ---- element properties ----
    for (int i = 0; i < count; i++)
    {
        Ref<VoxelElement> e = elements[i];
        if (e.is_null())
            continue;
        const String ctx = "element '" + e->get_element_name() + "'";
        GpuElementDef &d = defs[i];
        d.movement_class = (uint32_t)CLAMP(e->get_movement_class(), 0, 4);
        d.density = MAX(e->get_density(), 0.001f);
        d.flow = CLAMP(e->get_flow(), 0.0f, 1.0f);
        d.initial_temp_q = quantize_temp(e->get_initial_temp());
        d.heat_conduct = CLAMP(e->get_heat_conduct(), 0.0f, 1.0f);
        d.emission = e->get_emission();

        Color c = e->get_base_color().clamp();
        d.base_color16 = Utils::compress_color16(c) & 0xFFFFu;

        if (e->get_temp_high() > 0.0f && !e->get_state_high().is_empty())
        {
            d.temp_high_q = quantize_temp(e->get_temp_high());
            d.state_high = resolve_name(this, e->get_state_high(), 0, ctx + String(" state_high"));
        }
        if (e->get_temp_low() > 0.0f && !e->get_state_low().is_empty())
        {
            d.temp_low_q = quantize_temp(e->get_temp_low());
            d.state_low = resolve_name(this, e->get_state_low(), 0, ctx + String(" state_low"));
        }
        d.life_init = (uint32_t)CLAMP(e->get_life(), 0, 255);
        if (d.life_init > 0)
            d.life_into = resolve_name(this, e->get_life_into(), 0, ctx + String(" life_into"));
    }

    // ---- reactions (authored + generated mirror rules) ----
    for (int i = 0; i < count; i++)
    {
        Ref<VoxelElement> e = elements[i];
        if (e.is_null())
            continue;
        const String ctx = "element '" + e->get_element_name() + "'";
        Array reactions = e->get_reactions();
        for (int r = 0; r < reactions.size(); r++)
        {
            Ref<VoxelReaction> reaction = reactions[r];
            if (reaction.is_null())
                continue;
            int partner = find_element_id(reaction->get_partner());
            if (partner < 0)
            {
                UtilityFunctions::printerr("VoxelElementSet: unknown reaction partner '", reaction->get_partner(),
                                           "' on ", ctx);
                continue;
            }

            GpuReactionRule rule;
            rule.partner = (uint32_t)partner;
            rule.self_becomes = reaction->get_self_becomes().is_empty()
                                    ? ELEM_KEEP
                                    : resolve_name(this, reaction->get_self_becomes(), 0, ctx);
            rule.chance = (uint32_t)CLAMP(reaction->get_chance() * 10000.0f, 0.0f, 10000.0f);
            if (reaction->get_temp_min() > 0.0f)
                rule.temp_min_q = quantize_temp(reaction->get_temp_min());
            if (reaction->get_temp_max() > 0.0f)
                rule.temp_max_q = quantize_temp(reaction->get_temp_max());
            rule.temp_delta_q = (int32_t)(reaction->get_temp_delta() * 16.0f);
            rules_per[i].push_back(rule);

            // The partner's half of the reaction: same chance and gates, but the
            // gates keep testing the initiator's temperature so both sides make
            // an identical firing decision (pair-symmetric RNG does the rest).
            if (!reaction->get_oneway() && !reaction->get_partner_becomes().is_empty())
            {
                GpuReactionRule mirror;
                mirror.partner = (uint32_t)i;
                mirror.self_becomes = resolve_name(this, reaction->get_partner_becomes(), 0, ctx);
                mirror.chance = rule.chance;
                mirror.temp_min_q = rule.temp_min_q;
                mirror.temp_max_q = rule.temp_max_q;
                mirror.flags = REACTION_GATE_ON_PARTNER;
                rules_per[partner].push_back(mirror);
            }
        }
    }

    // ---- behavior ops (with symmetry expansion) ----
    std::vector<Vector3i> expanded;
    for (int i = 0; i < count; i++)
    {
        Ref<VoxelElement> e = elements[i];
        if (e.is_null())
            continue;
        const String ctx = "element '" + e->get_element_name() + "'";
        Array behavior = e->get_behavior();
        for (int o = 0; o < behavior.size(); o++)
        {
            Ref<VoxelBehaviorOp> op = behavior[o];
            if (op.is_null() || op->get_opcode() == VoxelBehaviorOp::OP_NONE)
                continue;

            uint32_t arg = 0;
            switch (op->get_opcode())
            {
            case VoxelBehaviorOp::OP_CREATE: {
                int id = find_element_id(op->get_element_a());
                if (id < 0)
                {
                    UtilityFunctions::printerr("VoxelElementSet: CREATE op with unknown element '",
                                               op->get_element_a(), "' on ", ctx);
                    continue;
                }
                arg = (uint32_t)id;
                break;
            }
            case VoxelBehaviorOp::OP_CHANGE: {
                uint32_t from = op->get_element_a().is_empty() ? ELEM_ANY
                                                               : resolve_name(this, op->get_element_a(), ELEM_ANY, ctx);
                uint32_t to = resolve_name(this, op->get_element_b(), 0, ctx);
                arg = (from << 16) | (to & 0xFFFFu);
                break;
            }
            default:
                arg = op->get_element_a().is_empty() ? ELEM_ANY : resolve_name(this, op->get_element_a(), ELEM_ANY, ctx);
                break;
            }

            expand_symmetry(op->get_offset(), op->get_symmetry(), expanded);
            for (const Vector3i &off : expanded)
            {
                GpuBehaviorOp gop;
                gop.packed_offset = pack_op_offset(off);
                gop.opcode = (uint32_t)op->get_opcode();
                gop.arg = arg;
                gop.chance = (uint32_t)CLAMP(op->get_chance() * 10000.0f, 0.0f, 10000.0f);
                ops_per[i].push_back(gop);
            }
        }
    }

    // ---- dynamic flag ----
    for (int i = 0; i < count; i++)
    {
        GpuElementDef &d = defs[i];
        bool moves = d.movement_class != (uint32_t)VoxelElement::MOVEMENT_STATIC;
        for (const GpuBehaviorOp &op : ops_per[i])
            if (op.opcode == VoxelBehaviorOp::OP_MOVE1 || op.opcode == VoxelBehaviorOp::OP_MOVE2 ||
                op.opcode == VoxelBehaviorOp::OP_SWAP)
                moves = true;
        if (i != 0 && moves) // air is never dynamic
            d.flags |= FLAG_DYNAMIC;
    }

    // ---- flatten ----
    std::vector<GpuReactionRule> all_rules;
    std::vector<GpuBehaviorOp> all_ops;
    for (int i = 0; i < count; i++)
    {
        defs[i].reaction_offset = (uint32_t)all_rules.size();
        defs[i].reaction_count = (uint32_t)rules_per[i].size();
        all_rules.insert(all_rules.end(), rules_per[i].begin(), rules_per[i].end());
        defs[i].behavior_offset = (uint32_t)all_ops.size();
        defs[i].behavior_count = (uint32_t)ops_per[i].size();
        all_ops.insert(all_ops.end(), ops_per[i].begin(), ops_per[i].end());
    }
    if ((int)all_rules.size() > MAX_REACTION_RULES)
    {
        UtilityFunctions::printerr("VoxelElementSet: reaction rule limit (4096) exceeded.");
        return false;
    }
    if ((int)all_ops.size() > MAX_BEHAVIOR_OPS)
    {
        UtilityFunctions::printerr("VoxelElementSet: behavior op limit (4096) exceeded.");
        return false;
    }

    r_element_table.resize(MAX_ELEMENTS * sizeof(GpuElementDef));
    std::memcpy(r_element_table.ptrw(), defs.data(), r_element_table.size());

    r_reaction_table.resize(MAX_REACTION_RULES * sizeof(GpuReactionRule));
    r_reaction_table.fill(0);
    if (!all_rules.empty())
        std::memcpy(r_reaction_table.ptrw(), all_rules.data(), all_rules.size() * sizeof(GpuReactionRule));

    r_behavior_table.resize(MAX_BEHAVIOR_OPS * sizeof(GpuBehaviorOp));
    r_behavior_table.fill(0);
    if (!all_ops.empty())
        std::memcpy(r_behavior_table.ptrw(), all_ops.data(), all_ops.size() * sizeof(GpuBehaviorOp));

    return true;
}

// -------------------------------------- defaults --------------------------------------

static Ref<VoxelElement> make_element(const String &name, int movement_class, float density, const Color &color,
                                      float conduct, float initial_temp)
{
    Ref<VoxelElement> e;
    e.instantiate();
    e->set_element_name(name);
    e->set_movement_class(movement_class);
    e->set_density(density);
    e->set_base_color(color);
    e->set_heat_conduct(conduct);
    e->set_initial_temp(initial_temp);
    return e;
}

Ref<VoxelElementSet> VoxelElementSet::create_default()
{
    Ref<VoxelElementSet> set;
    set.instantiate();

    // ids 0-7 are the builtins and must keep their positions
    Ref<VoxelElement> air = make_element("air", VoxelElement::MOVEMENT_STATIC, 1.0f, Color(0, 0, 0), 0.03f, 293.0f);
    Ref<VoxelElement> solid =
        make_element("solid", VoxelElement::MOVEMENT_STATIC, 2700.0f, Color(0.24f, 0.25f, 0.32f), 0.2f, 293.0f);

    Ref<VoxelElement> water =
        make_element("water", VoxelElement::MOVEMENT_LIQUID, 1000.0f, Color(0.1f, 0.3f, 0.8f), 0.6f, 293.0f);
    water->set_temp_high(373.0f);
    water->set_state_high("steam");
    water->set_temp_low(273.0f);
    water->set_state_low("ice");

    Ref<VoxelElement> lava =
        make_element("lava", VoxelElement::MOVEMENT_LIQUID, 2400.0f, Color(1.0f, 0.6f, 0.1f), 0.8f, 1500.0f);
    lava->set_flow(0.3f);
    lava->set_emission(1.0f);
    lava->set_temp_low(1000.0f);
    lava->set_state_low("solid");

    Ref<VoxelElement> sand =
        make_element("sand", VoxelElement::MOVEMENT_POWDER, 2650.0f, Color(0.91f, 0.82f, 0.52f), 0.25f, 293.0f);
    sand->set_temp_high(1873.0f);
    sand->set_state_high("glass");

    Ref<VoxelElement> vine =
        make_element("vine", VoxelElement::MOVEMENT_CUSTOM, 400.0f, Color(0.15f, 0.55f, 0.18f), 0.15f, 293.0f);

    Ref<VoxelElement> entity =
        make_element("entity", VoxelElement::MOVEMENT_STATIC, 1000.0f, Color(0.8f, 0.2f, 0.2f), 0.2f, 310.0f);
    Ref<VoxelElement> debug =
        make_element("debug", VoxelElement::MOVEMENT_STATIC, 1000.0f, Color(1.0f, 0.0f, 1.0f), 0.0f, 293.0f);

    // demo chemistry beyond the builtins
    Ref<VoxelElement> steam =
        make_element("steam", VoxelElement::MOVEMENT_GAS, 0.6f, Color(0.75f, 0.78f, 0.82f), 0.1f, 380.0f);
    steam->set_life(220);
    steam->set_life_into("water");

    Ref<VoxelElement> ice =
        make_element("ice", VoxelElement::MOVEMENT_STATIC, 917.0f, Color(0.65f, 0.8f, 0.95f), 0.4f, 260.0f);
    ice->set_temp_high(274.0f);
    ice->set_state_high("water");

    Ref<VoxelElement> fire =
        make_element("fire", VoxelElement::MOVEMENT_GAS, 0.3f, Color(1.0f, 0.45f, 0.08f), 0.9f, 1300.0f);
    fire->set_emission(2.0f);
    fire->set_life(40);
    fire->set_life_into(""); // burns out to air

    Ref<VoxelElement> glass =
        make_element("glass", VoxelElement::MOVEMENT_STATIC, 2500.0f, Color(0.7f, 0.85f, 0.9f), 0.15f, 293.0f);

    // freeze_lava.glsl parity, plus steam: lava touching water becomes rock,
    // the water flashes to steam
    Ref<VoxelReaction> quench = lava->add_reaction("water", "solid", "steam", 1.0f);
    (void)quench;

    // vines burn
    Ref<VoxelReaction> ignite = vine->add_reaction("fire", "fire", "", 0.12f);
    ignite->set_oneway(true);
    Ref<VoxelReaction> scorch = vine->add_reaction("lava", "fire", "", 0.05f);
    scorch->set_oneway(true);

    set->add_element(air);
    set->add_element(solid);
    set->add_element(water);
    set->add_element(lava);
    set->add_element(sand);
    set->add_element(vine);
    set->add_element(entity);
    set->add_element(debug);
    set->add_element(steam);
    set->add_element(ice);
    set->add_element(fire);
    set->add_element(glass);
    return set;
}

void VoxelElementSet::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("set_elements", "elements"), &VoxelElementSet::set_elements);
    ClassDB::bind_method(D_METHOD("get_elements"), &VoxelElementSet::get_elements);
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "elements", PROPERTY_HINT_ARRAY_TYPE,
                              String::num_int64(Variant::OBJECT) + "/" +
                                  String::num_int64(PROPERTY_HINT_RESOURCE_TYPE) + ":VoxelElement"),
                 "set_elements", "get_elements");

    ClassDB::bind_method(D_METHOD("add_element", "element"), &VoxelElementSet::add_element);
    ClassDB::bind_method(D_METHOD("find_element_id", "name"), &VoxelElementSet::find_element_id);
    ClassDB::bind_method(D_METHOD("get_element", "id"), &VoxelElementSet::get_element);
    ClassDB::bind_method(D_METHOD("get_element_by_name", "name"), &VoxelElementSet::get_element_by_name);
    ClassDB::bind_method(D_METHOD("get_element_count"), &VoxelElementSet::get_element_count);

    ClassDB::bind_static_method("VoxelElementSet", D_METHOD("create_default"), &VoxelElementSet::create_default);
}
