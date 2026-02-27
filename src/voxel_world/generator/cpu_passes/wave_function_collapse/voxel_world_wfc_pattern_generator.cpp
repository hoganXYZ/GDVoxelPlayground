// voxel_world_wfc_pattern_generator.cpp

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <memory>
#include <queue>
#include <random>
#include <string>
#include <unordered_map>
#include <vector>

#include "utility/bit_logic.h"
#include "voxel_world_wfc_pattern_generator.h"
#include "wfc_neighborhood.h"

using namespace godot;

// -------------------- Reused utilities (from adjacency WFC) --------------------

static constexpr float EPS = 1e-9f;

inline float safe_log(float x)
{
    return std::log(std::max(x, EPS));
}

// Shannon entropy over a dynamic vector
inline float shannon_entropy(const std::vector<float> &p, const std::vector<uint32_t> &domain_bits)
{
    float H = 0.0f;
    for (size_t w = 0; w < domain_bits.size(); ++w)
    {
        if (domain_bits[w] == 0)
            continue;
        for (size_t i = 0; i < 32 && (w * 32 + i) < p.size(); ++i)
        {
            if (domain_bits[w] & (1 << i))
            {
                float prob = p[w * 32 + i];
                if (prob > 0.0f)
                    H -= prob * safe_log(prob);
            }
        }
    }
    return H;
}

// Normalize; returns original sum
inline float normalize(std::vector<float> &p)
{
    float s = 0.0f;
    for (float v : p)
        s += v;
    if (s <= 0.0f)
        return 0.0f;
    const float inv = 1.0f / s;
    for (float &v : p)
        v *= inv;
    return s;
}

inline int weighted_sample_bits(const std::vector<float> &priors, const std::vector<uint32_t> &domain_bits,
                                std::mt19937 &rng)
{
    const int nwords = static_cast<int>(domain_bits.size());
    const int n = static_cast<int>(priors.size());

    // 1. Compute total weight of active entries
    float total = 0.0f;
    for (int w = 0; w < nwords; ++w)
    {
        uint32_t bits = domain_bits[w];
        if (!bits)
            continue;
        const int base = w * 32;
        while (bits)
        {
            int bit = ctz32(bits);
            int idx = base + bit;
            if (idx < n)
                total += priors[idx];
            bits &= bits - 1;
        }
    }
    if (total <= 0.0f)
        return -1;

    // 2. Pick threshold in [0, total)
    std::uniform_real_distribution<float> dist(0.0f, total);
    float r = dist(rng);

    // 3. Walk again until threshold is crossed
    float cum = 0.0f;
    for (int w = 0; w < nwords; ++w)
    {
        uint32_t bits = domain_bits[w];
        if (!bits)
            continue;
        const int base = w * 32;
        while (bits)
        {
            int bit = ctz32(bits);
            int idx = base + bit;
            if (idx < n)
            {
                cum += priors[idx];
                if (r <= cum)
                    return idx;
            }
            bits &= bits - 1;
        }
    }
    return -1; // Shouldn't get here if total > 0
}

// inline int weighted_sample(const std::vector<float> &p, std::mt19937 &rng)
// {
//     std::uniform_real_distribution<float> dist(0.0f, 1.0f);
//     float r = dist(rng);
//     float cum = 0.0f;
//     const int n = static_cast<int>(p.size());
//     for (int i = 0; i < n; ++i)
//     {
//         cum += p[i];
//         if (r <= cum)
//             return i;
//     }
//     for (int i = n - 1; i >= 0; --i)
//         if (p[i] > 0.0f)
//             return i;
//     return 0;
// }

// -------------------- Pattern data structures --------------------

struct Pattern
{
    std::vector<Voxel> voxels; // size = 1 + K
};

struct PatternKeyHash
{
    size_t operator()(const Pattern &p) const noexcept
    {
        uint64_t h = 1469598103934665603ULL; // FNV-1a 64-bit
        for (const Voxel &v : p.voxels)
        {
            uint32_t d = static_cast<uint32_t>(v.data);
            h ^= d;
            h *= 1099511628211ULL;
        }
        return size_t(h);
    }
};

struct PatternKeyEq
{
    bool operator()(const Pattern &a, const Pattern &b) const noexcept
    {
        return a.voxels == b.voxels;
    }
};

struct PatternModel
{
    int K = 0;                         // amount of offsets
    int D = 0;                         // amount of center deltas
    const Neighborhood *ngh = nullptr; // not owned

    std::vector<Pattern> patterns; // size P
    std::vector<float> priors;     // size P

    // Compatibility as bit masks: compat[k][a] is P bits packed in bytes
    // It essentially stores a P x P boolean compatability matrix for each direct offset k.
    // compat[k][a][b] == 1 means pattern b can be placed in direction k relative to a without conflict.
    std::vector<std::vector<std::vector<uint32_t>>> compat; // [K][P][Pbits/32]

    bool is_compatible(int d, int a, int b) const
    {
        if (d < 0 || d >= D || a < 0 || a >= (int)patterns.size() || b < 0 || b >= (int)patterns.size())
            return false;

        const auto &mask = compat[d][a];
        int word = b >> 5;
        int bit = b & 31;
        return (mask[word] & (1u << bit)) != 0;
    }
};

// -------------------- Grid cells (pattern WFC) --------------------

struct PatternCell
{
    enum class Kind : uint8_t
    {
        EMPTY,
        SUPERPOSITION,
        COLLAPSED
    };
    virtual ~PatternCell() = default;
    virtual Kind kind() const = 0;
};

struct EmptyCell : public PatternCell
{
    Kind kind() const override
    {
        return Kind::EMPTY;
    }
};

struct SuperpositionCell : PatternCell
{
    std::vector<uint32_t> domain_bits; // (P+31)/32 bytes
    float entropy = 0.0f;
    uint32_t version = 0; // if ~0, this cell is invalid
    Kind kind() const override
    {
        return Kind::SUPERPOSITION;
    }
};

struct CollapsedCell : public PatternCell
{
    int pattern_id = -1; // 0..P-1
    bool is_debug = false;
    Kind kind() const override
    {
        return Kind::COLLAPSED;
    }
};

// -------------------- Neighborhood helpers --------------------

inline int index_3d(const Vector3i &p, const Vector3i &size)
{
    return p.z * (size.x * size.y) + p.y * size.x + p.x;
}

inline bool in_bounds(const Vector3i &p, const Vector3i &size)
{
    return p.x >= 0 && p.x < size.x && p.y >= 0 && p.y < size.y && p.z >= 0 && p.z < size.z;
}

// -------------------- Pattern extraction and compatibility --------------------

static Pattern extract_pattern_voxels(const Ref<VoxelDataVox> &vox, const Vector3i &center, const Neighborhood &ngh)
{
    Pattern pat;
    pat.voxels.reserve(1 + ngh.get_K());
    for (auto &off : ngh.pattern())
        pat.voxels.push_back(vox->get_voxel_at(center + off));
    return pat;
}

static bool patterns_compatible_delta(const Neighborhood &ngh, const Pattern &A, const Pattern &B,
                                      const Vector3i &delta)
{
    // S = {0} ∪ offsets(); A/B.voxels are indexed: 0=center, 1..K = offsets()[i]
    auto offs = ngh.pattern();
    const int K = (int)offs.size();

    for (int i = 0; i < K; ++i)
    {
        const Vector3i posA = offs[i];
        const Vector3i posB = posA - delta;
        int idxB = ngh.index_including_center_for(posB);
        if (idxB >= 0)
        {
            if (A.voxels[i] != B.voxels[idxB])
                return false;
        }
    }
    return true;
}

static PatternModel build_pattern_model_from_neighborhood(const Ref<VoxelDataVox> &vox, const Vector3i &size,
                                                          const Neighborhood &ngh)
{
    PatternModel model;
    model.K = ngh.get_K();
    model.D = (int)ngh.center_deltas().size();
    model.ngh = &ngh;

    std::unordered_map<Pattern, int, PatternKeyHash, PatternKeyEq> pattern_ids;
    std::vector<uint32_t> counts;

    // 1) Extract unique patterns fully in bounds
    for (int z = 0; z < size.z; ++z)
        for (int y = 0; y < size.y; ++y)
            for (int x = 0; x < size.x; ++x)
            {
                Vector3i c(x, y, z);
                bool all_in = in_bounds(c, size);
                if (all_in)
                {
                    for (auto &off : ngh.offsets())
                    {
                        if (!in_bounds(c + off, size))
                        {
                            all_in = false;
                            break;
                        }
                    }
                }
                if (!all_in)
                    continue;

                Pattern pat = extract_pattern_voxels(vox, c, ngh);
                auto it = pattern_ids.find(pat);
                if (it == pattern_ids.end())
                {
                    int id = (int)model.patterns.size();
                    pattern_ids.emplace(pat, id);
                    model.patterns.push_back(std::move(pat));
                    counts.push_back(1);
                }
                else
                {
                    counts[it->second] += 1;
                }
            }

    const int P = (int)model.patterns.size();
    UtilityFunctions::print(String("Extracted ") + String::num_int64(P) + " unique patterns");
    model.priors.resize(P, 0.0f);
    uint64_t total = 0;
    for (auto cnt : counts)
        total += cnt;
    for (int i = 0; i < P; ++i)
        model.priors[i] = total ? float(counts[i]) / float(total) : 0.0f;

    // 2) Compatibility per delta: compat_delta[D][P][words]
    const int words_per_mask = (P + 31) / 32;
    model.compat.assign(model.D, std::vector<std::vector<uint32_t>>(P, std::vector<uint32_t>(words_per_mask, 0)));

    for (int d = 0; d < model.D; ++d)
    {
        const Vector3i delta = ngh.center_deltas()[d];
        for (int a = 0; a < P; ++a)
        {
            auto &mask = model.compat[d][a];
            for (int b = 0; b < P; ++b)
            {
                if (patterns_compatible_delta(*model.ngh, model.patterns[a], model.patterns[b], delta))
                {
                    mask[b >> 5] |= (1 << (b & 31));
                }
            }
        }
    }

    return model;
}

void debug_place_and_print_patterns(PatternModel &model, const Neighborhood &ngh, std::vector<Voxel> &result_voxels,
                                    const VoxelWorldProperties &properties)
{
    float epsilon = 1e-8f;
    int P = static_cast<int>(model.patterns.size());

    const auto &grid_size = properties.grid_size; // assume Vector3i or similar
    // std::vector<Voxel> result_voxels(voxel_world_rids.voxel_count, Voxel::create_air_voxel());

    // --- 1) Pattern placement in debug order ---
    int gap_x = 1, gap_y = 2, gap_z = 3;

    Vector3i cursor(0, 0, 0);
    for (int pid = 0; pid < P; ++pid)
    {
        const auto &pat = model.patterns[pid];
        Vector3i pat_size = Vector3i(3, 3, 3); // you need a way to know pattern voxel extents

        // Skip if it doesn't fit at current cursor
        if (cursor.x + pat_size.x > grid_size.x || cursor.y + pat_size.y > grid_size.y ||
            cursor.z + pat_size.z > grid_size.z)
        {
            // Move to next row/column
            cursor.x = 0;
            cursor.y += pat_size.y + gap_y;

            // If Y overflow, reset Y and go up in Z
            if (cursor.y + pat_size.y > grid_size.y)
            {
                cursor.y = 0;
                cursor.z += pat_size.z + gap_z;
            }

            // Check final fit after advancing
            if (cursor.z + pat_size.z > grid_size.z)
                break; // world full in Z
        }

        // Place pattern voxels
        for (int k = 0; k < ngh.get_K() + 1; ++k)
        {
            Vector3i xyz = Vector3i(1, 1, 1) + ((k == 0) ? Vector3i(0, 0, 0) : ngh.offsets()[k - 1]);
            int idx = properties.pos_to_voxel_index(cursor + xyz);
            result_voxels[idx] = pat.voxels[k];
        }

        // Advance X
        cursor.x += pat_size.x + gap_x;

        // Wrap X
        if (cursor.x + pat_size.x > grid_size.x)
        {
            cursor.x = 0;
            cursor.y += pat_size.y + gap_y;
            if (cursor.y + pat_size.y > grid_size.y)
            {
                cursor.y = 0;
                cursor.z += pat_size.z + gap_z;
            }
        }
    }

    // --- 2) Pattern priors ---
    String s = "Priors (non-zero):\n";
    for (int i = 0; i < P; ++i)
    {
        float p = model.priors[i];
        if (p > epsilon)
            s += String::num_int64(i) + ": " + String::num(p, 6) + "\n";
    }
    UtilityFunctions::print(s);

    // --- 3) Adjacency per direction ---
    for (int d = 0; d < ngh.get_K(); ++d)
    {
        String block;
        auto offset = ngh.offsets()[d];
        String dir = "(" + String::num_int64(offset.x) + "," + String::num_int64(offset.y) + "," +
                     String::num_int64(offset.z) + ")";
        block += "Dir " + dir + " adjacency (non-zero):\n";

        for (int i = 0; i < P; ++i)
        {
            String line;
            bool any = false;
            for (int j = 0; j < P; ++j)
            {
                if (model.is_compatible(d, i, j))
                {
                    if (!any)
                    {
                        line = String::num_int64(i) + " -> ";
                        any = true;
                    }
                    else
                        line += String(", ");

                    line += String::num_int64(j);
                }
            }
            if (any)
                block += line + "\n";
        }
        UtilityFunctions::print(block);
    }
}

void debug_place_pattern_pairs(PatternModel &model, const Neighborhood &ngh, std::vector<Voxel> &result_voxels,
                               const VoxelWorldProperties &properties, int N_examples, uint32_t rng_seed = 12345)
{
    int P = static_cast<int>(model.patterns.size());
    if (P == 0)
        return;

    const auto &grid_size = properties.grid_size;

    // Base spacing + extra padding around each 2‑pattern block
    const int gap_x = 1 + 1; // +1 padding around pair
    const int gap_y = 2 + 2;
    const int gap_z = 3 + 3;

    Vector3i pat_size(3, 3, 3);     // same for all patterns here
    Vector3i block_size = pat_size; // will enlarge below for pair

    // A pair's bounding box in placement space = both patterns in one dir
    // If you place neighbor along X, width = 2*pat_size.x
    // We'll be conservative and just add pat_size in largest dimension + gap
    block_size.x = pat_size.x * 2;
    block_size.y = pat_size.y * 2;
    block_size.z = pat_size.z * 2;

    Vector3i cursor(0, 0, 0);

    std::mt19937 rng(rng_seed);
    std::discrete_distribution<int> priors_dist(model.priors.begin(), model.priors.end());

    for (int ex = 0; ex < N_examples; ++ex)
    {
        // --- Fit check ---
        if (cursor.x + block_size.x > grid_size.x || cursor.y + block_size.y > grid_size.y ||
            cursor.z + block_size.z > grid_size.z)
        {
            cursor.x = 0;
            cursor.y += block_size.y + gap_y;

            if (cursor.y + block_size.y > grid_size.y)
            {
                cursor.y = 0;
                cursor.z += block_size.z + gap_z;
            }
            if (cursor.z + block_size.z > grid_size.z)
                break; // out of space
        }

        // --- Pick random base pattern a ---
        int a = priors_dist(rng);

        // Pick random direction
        const auto &deltas = ngh.center_deltas();
        std::uniform_int_distribution<int> dir_dist(0, deltas.size() - 1);
        int d = dir_dist(rng);
        Vector3i dir_offset = deltas[d];

        // Pick random compatible neighbor b
        const auto &mask = model.compat[d][a];
        std::vector<int> allowed;
        allowed.reserve(P);
        for (int b_id = 0; b_id < P; ++b_id)
        {
            // if()
            if (model.compat[d][a][b_id >> 5] & (1u << (b_id & 31)))
            {
                allowed.push_back(b_id);
            }
        }
        if (allowed.empty())
            continue; // no neighbor possible in this dir
        std::uniform_int_distribution<size_t> bdist(0, allowed.size() - 1);
        int b = allowed[bdist(rng)];

        // --- Place pattern a ---
        for (int slot = 0; slot < ngh.get_K() + 1; ++slot)
        {
            Vector3i local = ngh.pattern()[slot];
            Vector3i pos_world = cursor + (local + Vector3i(1, 1, 1)); // center offset in block
            int idx = properties.pos_to_voxel_index(pos_world);
            if (idx >= 0 && idx < (int)result_voxels.size())
                result_voxels[idx] = model.patterns[a].voxels[slot];
        }

        // --- Place pattern b relative to a in dir k ---
        Vector3i b_origin = cursor + (dir_offset * 1) + Vector3i(1, 1, 1);
        for (int slot = 0; slot < ngh.get_K() + 1; ++slot)
        {
            Vector3i local = ngh.pattern()[slot];
            Vector3i pos_world = b_origin + local;
            int idx = properties.pos_to_voxel_index(pos_world);
            if (idx >= 0 && idx < (int)result_voxels.size())
                result_voxels[idx] = model.patterns[b].voxels[slot];
        }

        // Advance cursor in X
        cursor.x += block_size.x + gap_x;
        if (cursor.x + block_size.x > grid_size.x)
        {
            cursor.x = 0;
            cursor.y += block_size.y + gap_y;
            if (cursor.y + block_size.y > grid_size.y)
            {
                cursor.y = 0;
                cursor.z += block_size.z + gap_z;
            }
        }
    }
}

struct CompatMismatch
{
    int k, a, b;
    bool expected, got;
};

std::vector<CompatMismatch> validate_compat(const PatternModel &model)
{
    std::vector<CompatMismatch> mismatches;
    int D = model.D;
    int P = static_cast<int>(model.patterns.size());
    for (int d = 0; d < D; ++d)
    {
        Vector3i delta = model.ngh->center_deltas()[d];
        for (int a = 0; a < P; ++a)
        {
            for (int b = 0; b < P; ++b)
            {
                bool expected = patterns_compatible_delta(*model.ngh, model.patterns[a], model.patterns[b], delta);
                bool got = model.is_compatible(d, a, b);
                if (expected != got)
                    mismatches.push_back({d, a, b, expected, got});
            }
        }
    }
    return mismatches;
}

// -------------------- Generator --------------------
bool VoxelWorldWFCPatternGenerator::generate(std::vector<Voxel> &result_voxels, const Vector3i bounds_min,
                                             const Vector3i bounds_max, const VoxelWorldProperties &properties)
// std::vector<Voxel> VoxelWorldWFCPatternGenerator::generate(const Vector3i bounds_min, const Vector3i bounds_max,
// const VoxelWorldProperties &properties)
{
    if (voxel_data.is_null())
    {
        ERR_PRINT("Voxel data is not set for the WFC pattern generator.");
        return false;
    }
    voxel_data->load();

    std::unique_ptr<NeighborhoodBase> ngh = std::make_unique<Moore>(neighborhood_radius, use_exhaustive_offsets);

    switch (neighborhood_type)
    {
    case NEIGHBORHOOD_VON_NEUMANN:
        ngh = std::make_unique<VonNeumann>(neighborhood_radius, use_exhaustive_offsets);
        break;
    default:
        break;
    }

    // Template extraction
    const Vector3i template_size = voxel_data->get_size();
    PatternModel model = build_pattern_model_from_neighborhood(voxel_data, template_size, *ngh);
    const int P = static_cast<int>(model.patterns.size());
    if (P == 0)
    {
        ERR_PRINT("PatternWFC: No patterns to work with.");
        return false;
    }

    // debug_place_and_print_patterns(model, ngh, result_voxels, properties);
    // UtilityFunctions::print("PatternWFC: Amount of mismatches between compat and exhaustive check: ",
    // validate_compat(model).size();
    // debug_place_pattern_pairs(model, ngh, result_voxels, properties, 10000,
    // Time::get_singleton()->get_unix_time_from_system()); return true;

    // Output grid size
    Vector3i grid_size(properties.grid_size.x, properties.grid_size.y, properties.grid_size.z);
    grid_size = grid_size.min(target_grid_size);

    const int N = grid_size.x * grid_size.y * grid_size.z;

    // Grid cells
    std::vector<std::unique_ptr<PatternCell>> grid;
    grid.reserve(N);
    for (int i = 0; i < N; ++i)
        grid.emplace_back(std::make_unique<EmptyCell>());

    auto pos_from_index = [&](int idx) -> Vector3i {
        int x = idx % grid_size.x;
        int y = (idx / grid_size.x) % grid_size.y;
        int z = idx / (grid_size.x * grid_size.y);
        return Vector3i(x, y, z);
    };

    auto collapse_to_pattern = [&](int idx, int pattern_id, bool is_debug = false) {
        auto cv = std::make_unique<CollapsedCell>();
        cv->pattern_id = pattern_id;
        cv->is_debug = is_debug;
        grid[idx] = std::move(cv);
    };

    // Initialize RNG
    std::mt19937 rng(Time::get_singleton()->get_unix_time_from_system());

    // Min-heap for selecting next collapse (lowest entropy first)
    struct HeapNode
    {
        float entropy;
        int index;
        uint32_t version;
        uint64_t tick;
    };

    struct HeapCompare
    {
        bool operator()(const HeapNode &a, const HeapNode &b) const
        {
            if (a.entropy != b.entropy)
                return a.entropy > b.entropy; // min-heap on entropy
            return a.tick > b.tick;           // larger tick = more recent
        }
    };

    std::priority_queue<HeapNode, std::vector<HeapNode>, HeapCompare> heap;

    // setup superposition cells
    normalize(model.priors); // ensure priors sum to 1.0
    const size_t Pbits = model.priors.size();
    const size_t Pwords = (Pbits + 31) / 32;
    float priors_entropy = shannon_entropy(model.priors, std::vector<uint32_t>(Pwords, ~0u));

    // Precompute an all-ones mask (with tail clamp) for early exits.
    std::vector<uint32_t> ALL1(Pwords, ~0u);
    if (Pbits & 31)
    {
        uint32_t tailmask = (~0u) >> (32 - (Pbits & 31));
        ALL1[Pwords - 1] = tailmask;
    }

    // Popcount for bitset domain
    auto popcount_bits = [&](const std::vector<uint32_t> &bits) -> int {
        int c = 0;
        for (uint32_t w : bits)
            c += popcount32(w);
        return c;
    };

    // Small helper to check "mask is saturated"
    auto is_all_ones = [&](const std::vector<uint32_t> &mask) -> bool {
        for (size_t i = 0; i < Pwords; ++i)
            if (mask[i] != ALL1[i])
                return false;
        return true;
    };

    auto init_superposition_from_priors = [&](int idx) -> SuperpositionCell * {
        auto sp = std::make_unique<SuperpositionCell>();
        sp->domain_bits.resize(Pwords, ~0u);
        sp->entropy = priors_entropy;
        sp->version = 0;
        auto *raw = sp.get();
        grid[idx] = std::move(sp);
        return raw;
    };

    // AND a precomputed mask into tgt; updates entropy/version and signals if any bits changed or contradiction
    auto apply_mask = [&](SuperpositionCell &tgt, const std::vector<uint32_t> &mask) -> bool {
        bool any_changed = false;
        bool all_zero = true;

        for (size_t w = 0; w < Pwords; ++w)
        {
            uint32_t before = tgt.domain_bits[w];
            uint32_t after = before & mask[w];

            // tail clamp for last partial word
            if (w == Pwords - 1 && (Pbits & 31))
            {
                uint32_t tailmask = (~0u) >> (32 - (Pbits & 31));
                after &= tailmask;
            }

            if (after != before)
                any_changed = true;
            if (after)
                all_zero = false;
            tgt.domain_bits[w] = after;
        }

        if (all_zero)
        {
            tgt.version = ~0u; // contradiction marker
            return true;       // signal "changed" to trigger handling
        }

        if (!any_changed)
            return false;

        tgt.version += 1;
        tgt.entropy = shannon_entropy(model.priors, tgt.domain_bits);
        return true;
    };

    // Single-pattern propagation (existing behavior)
    auto apply_compat_single = [&](SuperpositionCell &tgt, int d, int neighbor_pattern_id) -> bool {
        const auto &mask = model.compat[d][neighbor_pattern_id];
        return apply_mask(tgt, mask);
    };

    // scratch mask reused each call
    std::vector<uint32_t> union_mask;
    union_mask.resize(Pwords);

    // Build union-of-compatibility for direction d against a source domain.
    // Keeps arc consistency: target allowed iff supported by at least one source pattern.
    auto build_union_mask_from_bits = [&](int d, const std::vector<uint32_t> &bits) -> const std::vector<uint32_t> & {
        std::fill(union_mask.begin(), union_mask.end(), 0u);

        // If domain is small, this stays cheap; if it grows, we likely saturate — early exit once saturated.
        for (size_t w = 0; w < bits.size(); ++w)
        {
            uint32_t word = bits[w];
            if (!word)
                continue;

            const int base = static_cast<int>(w << 5); // w*32
            while (word)
            {
                int bit = ctz32(word);
                const int pat = base + bit;
                if (pat < static_cast<int>(Pbits))
                {
                    const auto &cm = model.compat[d][pat];
                    // OR and check for new bits; if saturated, return early
                    for (size_t ww = 0; ww < Pwords; ++ww)
                    {
                        union_mask[ww] |= cm[ww];
                    }
                    // Tail clamp once at the end is fine, but we can also short-circuit if saturated
                    // (Cheap check; avoids tail clamp each time)
                    if (is_all_ones(union_mask))
                    {
                        // Ensure tail is clamped before returning
                        if (Pbits & 31)
                        {
                            uint32_t tailmask = (~0u) >> (32 - (Pbits & 31));
                            union_mask[Pwords - 1] &= tailmask;
                        }
                        return union_mask;
                    }
                }
                word &= (word - 1); // clear LSB
            }
        }
        // mask tail in last word
        if (Pbits & 31)
        {
            uint32_t tailmask = (~0u) >> (32 - (Pbits & 31));
            union_mask[Pwords - 1] &= tailmask;
        }
        return union_mask;
    };

    auto init_from_single_neighbor = [&](int idx, int d, int neighbor_pattern_id) -> PatternCell * {
        auto *sp = init_superposition_from_priors(idx);
        if (!sp)
            return nullptr;
        apply_compat_single(*sp, d, neighbor_pattern_id);
        if (sp->version == ~0u)
        {
            auto cl = std::make_unique<CollapsedCell>();
            cl->pattern_id = 0;
            cl->is_debug = true;
            auto *raw = cl.get();
            grid[idx] = std::move(cl);
            return raw;
        }
        return sp;
    };

    uint64_t global_tick = 0;

    // For strong propagation: a small work-queue and an in-queue marker
    std::deque<int> wave_q;
    std::vector<uint8_t> in_wave;
    std::vector<uint8_t> dirty;    // mark cells whose entropy changed during wave
    std::vector<int> pending_heap; // gather cells to push to heap after wave settles

    if (enable_superposition_propagation)
    {
        in_wave.assign(N, 0);
        dirty.assign(N, 0);
        pending_heap.reserve(128);
    }

    // --- Optional: bootstrap from an initial generator pass ---
    bool bootstrapped = false;
    bool created_any_superposition = false;

    if (initial_state.is_valid())
    {
        // 1) Generate initial voxel state using the same bounds as this pass.
        std::vector<Voxel> initial_voxels(result_voxels.size(), Voxel::create_air_voxel());
        bool ok = initial_state->generate(initial_voxels, bounds_min, bounds_max, properties);

        if (ok)
        {
            // Helper: get voxel from initial_voxels at world position, or a sentinel air if OOB.
            auto get_initial_voxel = [&](const Vector3i &world_pos) -> Voxel {
                int idx = properties.pos_to_voxel_index(world_pos);
                if (idx < 0 || idx >= (int)initial_voxels.size())
                    return Voxel::create_air_voxel();
                return initial_voxels[idx];
            };

            auto pick_weighted_pattern_at = [&](int i) -> int {
                Vector3i c_local = pos_from_index(i);
                Vector3i c_world = c_local + bounds_min;

                std::vector<int> candidates;
                std::vector<float> weights;
                candidates.reserve(P);
                weights.reserve(P);

                for (int pid = 0; pid < P; ++pid)
                {
                    bool match = true;
                    for (int k = 0; k < ngh->get_K() + 1; ++k)
                    {
                        const Vector3i off = ngh->pattern()[k];
                        const auto v = get_initial_voxel(c_world + off);
                        const auto &pattern_voxel = model.patterns[pid].voxels[k];
                        if (!v.is_air() && v != pattern_voxel)
                        {
                            match = false;
                            break;
                        }
                    }
                    if (match)
                    {
                        candidates.push_back(pid);
                        weights.push_back(model.priors[pid]);
                    }
                }

                if (candidates.empty())
                    return -1;

                // Weighted random choice
                float total_w = 0.0f;
                for (float w : weights)
                    total_w += w;
                std::uniform_real_distribution<float> dist(0.0f, 1.0f);
                float r = dist(rng);
                if (total_w <= 0.0f)
                {
                    return candidates[std::floor(r * candidates.size())];
                }
                r = r * total_w;
                for (size_t ci = 0; ci < candidates.size(); ++ci)
                {
                    r -= weights[ci];
                    if (r <= 0.0f)
                        return candidates[ci];
                }
                return candidates.back(); // fallback
            };

            std::vector<int> collapsed_indices;
            std::vector<int> collapsed_pids;
            collapsed_indices.reserve(N);
            collapsed_pids.reserve(N);

            for (int i = 0; i < N; ++i)
            {
                Vector3i wpos = pos_from_index(i) + bounds_min;
                Voxel v = get_initial_voxel(wpos);
                if (v.is_air())
                {
                    continue; // leave empty
                }

                int pid = pick_weighted_pattern_at(i);
                if (pid >= 0)
                {
                    collapse_to_pattern(i, pid, /*is_debug*/ false);
                    collapsed_indices.push_back(i);
                    collapsed_pids.push_back(pid);
                }
                else
                {
                    collapse_to_pattern(i, 0, /*is_debug*/ true);
                }
            }

            // 3) Apply constraints from collapsed cells to their neighbors.
            const auto &deltas = ngh->center_deltas();
            const int D = (int)deltas.size();

            for (size_t ci = 0; ci < collapsed_indices.size(); ++ci)
            {
                int idx = collapsed_indices[ci];
                int pid = collapsed_pids[ci];
                Vector3i pos = pos_from_index(idx);

                for (int d = 0; d < D; ++d)
                {
                    Vector3i np = pos + deltas[d];
                    if (!in_bounds(np, grid_size))
                        continue;
                    int nidx = index_3d(np, grid_size);

                    auto k = grid[nidx]->kind();
                    if (k == PatternCell::Kind::EMPTY)
                    {
                        // Create a superposition from priors and constrain it by this collapsed neighbor.
                        if (auto *tgt = init_superposition_from_priors(nidx))
                        {
                            bool changed = apply_compat_single(*tgt, d, pid);
                            // Even if no bits were pruned, we still created a superposition.
                            created_any_superposition = true;

                            if (changed && tgt->version != ~0u)
                            {
                                if (enable_superposition_propagation)
                                {
                                    if (!in_wave.empty())
                                    { // in_wave allocated only when propagation is enabled
                                        if (!in_wave[nidx])
                                        {
                                            wave_q.push_back(nidx);
                                            in_wave[nidx] = 1;
                                        }
                                    }
                                    if (!dirty.empty())
                                        dirty[nidx] = 1;
                                }
                                else
                                {
                                    heap.push({tgt->entropy, nidx, tgt->version, global_tick++});
                                }
                            }
                            else if (!enable_superposition_propagation)
                            {
                                // Push anyway so it participates in entropy selection
                                heap.push({tgt->entropy, nidx, tgt->version, global_tick++});
                            }
                        }
                    }
                    else if (k == PatternCell::Kind::SUPERPOSITION)
                    {
                        auto *tgt = static_cast<SuperpositionCell *>(grid[nidx].get());
                        bool changed = apply_compat_single(*tgt, d, pid);
                        if (changed)
                        {
                            if (tgt->version < ~0u)
                                tgt->version += 1;
                            if (enable_superposition_propagation)
                            {
                                if (tgt->version < ~0u && !in_wave[nidx])
                                {
                                    wave_q.push_back(nidx);
                                    in_wave[nidx] = 1;
                                }
                                if (!dirty.empty())
                                    dirty[nidx] = 1;
                            }
                            else
                            {
                                heap.push({tgt->entropy, nidx, tgt->version, global_tick++});
                            }
                        }
                    }
                    // If neighbor is already collapsed, nothing to do here.
                }
            }

            // If we batched changes, schedule them now.
            if (enable_superposition_propagation)
            {
                for (int i = 0; i < N; ++i)
                {
                    if (!dirty.empty() && !dirty[i])
                        continue;
                    if (!grid[i] || grid[i]->kind() != PatternCell::Kind::SUPERPOSITION)
                        continue;
                    auto *t = static_cast<SuperpositionCell *>(grid[i].get());
                    if (t->version == ~0u)
                        continue;
                    heap.push({t->entropy, i, t->version, global_tick++});
                    if (!dirty.empty())
                        dirty[i] = 0;
                }
            }

            bootstrapped = true;
        }
    }

    // If bootstrapped and we created at least one superposition, skip entropy seed; otherwise seed as usual.
    if (!bootstrapped || !created_any_superposition)
    {
        int seed_idx = index_3d((seed_position_normalized * grid_size).floor(), grid_size);
        if (seed_idx < 0 || seed_idx >= N)
            seed_idx = 0;
        SuperpositionCell *seed_sp = init_superposition_from_priors(seed_idx);
        if (seed_sp)
            heap.push(HeapNode{seed_sp->entropy, seed_idx, seed_sp->version, global_tick++});
    }

    const auto &deltas = ngh->center_deltas();
    const int D = static_cast<int>(deltas.size());

    // Main loop
    while (!heap.empty())
    {
        HeapNode node = heap.top();
        heap.pop();
        if (grid[node.index]->kind() != PatternCell::Kind::SUPERPOSITION)
            continue;
        auto *sp = static_cast<SuperpositionCell *>(grid[node.index].get());
        if (sp->version != node.version)
            continue; // stale

        // Collapse
        int pat_id = weighted_sample_bits(model.priors, sp->domain_bits, rng);
        bool invalid = sp->version == ~0u; // || pat_id < 0;
        collapse_to_pattern(node.index, std::max(0, pat_id), invalid);
        if (invalid)
            continue;

        // Propagate to neighbors
        Vector3i pos = pos_from_index(node.index);

        // Seed list of neighbors changed by the immediate single-pattern propagation
        if (enable_superposition_propagation)
            wave_q.clear();

        for (int d = 0; d < D; ++d)
        {
            Vector3i np = pos + deltas[d];
            if (!in_bounds(np, grid_size))
                continue;
            int nidx = index_3d(np, grid_size);

            auto kind = grid[nidx]->kind();
            if (kind == PatternCell::Kind::EMPTY)
            {
                if (auto *tgt_cell = init_from_single_neighbor(nidx, d, pat_id))
                {
                    if (tgt_cell->kind() == PatternCell::Kind::SUPERPOSITION)
                    {
                        auto *tgt = static_cast<SuperpositionCell *>(tgt_cell);
                        if (enable_superposition_propagation)
                        {
                            if (!in_wave[nidx])
                            {
                                wave_q.push_back(nidx);
                                in_wave[nidx] = 1;
                            }
                            dirty[nidx] = 1; // mark for later heap push
                        }
                        else
                        {
                            heap.push({tgt->entropy, nidx, tgt->version, global_tick++});
                        }
                    }
                    // If it became collapsed due to contradiction handling, nothing to enqueue
                }
            }
            else if (kind == PatternCell::Kind::SUPERPOSITION)
            {
                auto *tgt = static_cast<SuperpositionCell *>(grid[nidx].get());
                bool changed = apply_compat_single(*tgt, d, pat_id);
                if (changed)
                {
                    if (enable_superposition_propagation)
                    {
                        if (tgt->version < ~0u && !in_wave[nidx])
                        {
                            wave_q.push_back(nidx);
                            in_wave[nidx] = 1;
                        }
                        dirty[nidx] = 1;
                    }
                    else
                    {
                        heap.push({tgt->entropy, nidx, tgt->version, global_tick++});
                    }
                }
            }
        }

        // Optionally: also seed the collapsed source itself into the wave to propagate further hops immediately
        if (enable_superposition_propagation)
        {
            int sidx = node.index;
            if (!in_wave[sidx])
            {
                wave_q.push_back(sidx);
                in_wave[sidx] = 1;
            }
        }

        if (enable_superposition_propagation)
        {
            while (!wave_q.empty())
            {
                int src_idx = wave_q.front();
                wave_q.pop_front();
                in_wave[src_idx] = 0;

                if (!grid[src_idx])
                    continue;

                Vector3i spos = pos_from_index(src_idx);

                // Determine source “mode”
                bool src_is_sp = (grid[src_idx]->kind() == PatternCell::Kind::SUPERPOSITION);
                const std::vector<uint32_t> *src_bits = nullptr;
                int src_single_pat = -1;

                if (src_is_sp)
                {
                    auto *src_sp = static_cast<SuperpositionCell *>(grid[src_idx].get());
                    // If contradiction, skip
                    if (src_sp->version >= ~0u)
                        continue;
                    int pc = popcount_bits(src_sp->domain_bits);
                    if (pc == 0)
                        continue; // defensive
                    if (pc == 1)
                    {
                        // Extract the single pattern id
                        for (size_t w = 0; w < src_sp->domain_bits.size(); ++w)
                        {
                            uint32_t word = src_sp->domain_bits[w];
                            if (word)
                            {
                                int bit = ctz32(word);
                                src_single_pat = static_cast<int>((w << 5) + bit);
                                break;
                            }
                        }
                        src_is_sp = false; // treat as collapsed for propagation
                    }
                    else
                    {
                        src_bits = &src_sp->domain_bits;
                    }
                }
                else if (grid[src_idx]->kind() == PatternCell::Kind::COLLAPSED)
                {
                    auto *src_cl = static_cast<CollapsedCell *>(grid[src_idx].get());
                    src_single_pat = src_cl->pattern_id;
                }
                else
                {
                    continue;
                }

                for (int d = 0; d < D; ++d)
                {
                    Vector3i np = spos + deltas[d];
                    if (!in_bounds(np, grid_size))
                        continue;
                    int nidx = index_3d(np, grid_size);

                    if (!grid[nidx] || grid[nidx]->kind() != PatternCell::Kind::SUPERPOSITION)
                        continue;
                    auto *tgt = static_cast<SuperpositionCell *>(grid[nidx].get());
                    if (tgt->version >= ~0u)
                        continue; // already contradictory

                    bool changed = false;
                    if (src_single_pat >= 0)
                    {
                        // Fast path: single-pattern support
                        changed = apply_compat_single(*tgt, d, src_single_pat);
                    }
                    else
                    {
                        // General case: union-of-compatibility from source superposition
                        const auto &um = build_union_mask_from_bits(d, *src_bits);
                        changed = apply_mask(*tgt, um);
                    }

                    if (changed)
                    {
                        // If still a valid superposition, keep propagating
                        if (tgt->version < ~0u && !in_wave[nidx])
                        {
                            wave_q.push_back(nidx);
                            in_wave[nidx] = 1;
                        }

                        // Mark for a single heap push after wave finishes
                        dirty[nidx] = 1;
                    }
                }
            }

            // Now batch-push changed cells to the heap once the wave stabilized
            pending_heap.clear();
            for (int i = 0; i < N; ++i)
            {
                if (!dirty[i])
                    continue;
                dirty[i] = 0;

                if (!grid[i] || grid[i]->kind() != PatternCell::Kind::SUPERPOSITION)
                    continue;
                auto *t = static_cast<SuperpositionCell *>(grid[i].get());
                if (t->version >= ~0u)
                    continue; // contradictory

                pending_heap.push_back(i);
            }
            for (int idx : pending_heap)
            {
                auto *t = static_cast<SuperpositionCell *>(grid[idx].get());
                heap.push({t->entropy, idx, t->version, global_tick++});
            }
        }
    }

    Vector3i scaled_size = (Vector3(grid_size) * voxel_scale).ceil();

    for (int z = 0; z < scaled_size.z; ++z)
        for (int y = 0; y < scaled_size.y; ++y)
            for (int x = 0; x < scaled_size.x; ++x)
            // for (int i = 0; i < N; ++i)
            {
                Vector3i pos(x, y, z);
                // Vector3i pos = pos_from_index(i);
                if (!properties.isValidPos(pos + bounds_min))
                    continue;

                int i = index_3d((Vector3(pos) / voxel_scale).floor(), grid_size);

                int result_idx = properties.pos_to_voxel_index(pos + bounds_min);
                if (result_idx < 0 || result_idx >= static_cast<int>(result_voxels.size()))
                    continue;
                if (!grid[i] || (!result_voxels[result_idx].is_air() && only_replace_air))
                    continue;
                if (grid[i]->kind() == PatternCell::Kind::COLLAPSED)
                {
                    auto *cv = static_cast<CollapsedCell *>(grid[i].get());
                    int pid = cv->pattern_id;
                    if (cv->is_debug)
                    {
                        if (show_contradictions)
                            result_voxels[result_idx] =
                                Voxel::create_voxel(Voxel::VOXEL_TYPE_SOLID, Color(1.0f, 0.0f, 1.0f));
                    }
                    else if (pid >= 0 && pid < P)
                    {
                        Voxel v = model.patterns[pid].voxels[0];
                        Color c = v.get_color();
                        int type = v.get_type();
                        if (add_color_noise)
                            c = Utils::randomized_color(c);

                        v = Voxel::create_voxel(type, c);
                        result_voxels[result_idx] = v;
                    }
                }
            }

    return true;
}
