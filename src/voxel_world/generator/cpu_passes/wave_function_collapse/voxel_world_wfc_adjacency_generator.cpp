#include "voxel_world_wfc_adjacency_generator.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <godot_cpp/classes/time.hpp>
#include <limits>
#include <memory>
#include <queue>
#include <random>
#include <unordered_map>
#include <vector>

#include "wfc_neighborhood.h"
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

// Constants
static constexpr int T = 256; // palette size
static constexpr float EPS = 1e-9f;
static constexpr uint8_t DEBUG_TILE_ID = 255; // magenta/debug fallback (adjust to your palette)

// Track which voxel IDs we've seen in the seed data
std::unordered_map<Voxel, uint8_t> voxel_to_palette_index;

namespace
{

// Base class
struct WFCVoxel
{
    enum class Kind : uint8_t
    {
        EMPTY,
        SUPERPOSITION,
        COLLAPSED
    };
    virtual ~WFCVoxel() = default;
    virtual Kind kind() const = 0;
};

// Empty
struct EmptyVoxel : public WFCVoxel
{
    Kind kind() const override
    {
        return Kind::EMPTY;
    }
};

// Superposition (probability vector)
struct SuperpositionVoxel : public WFCVoxel
{
    std::array<float, T> p{};
    float entropy = 0.0f;
    uint32_t version = 0; // bump whenever p changes
    Kind kind() const override
    {
        return Kind::SUPERPOSITION;
    }
};

// Collapsed
struct CollapsedVoxel : public WFCVoxel
{
    uint8_t type = 0;
    bool is_debug = false;
    Kind kind() const override
    {
        return Kind::COLLAPSED;
    }
};

// Helpers
inline int index_3d(const Vector3i &p, const Vector3i &size)
{
    return p.z * (size.x * size.y) + p.y * size.x + p.x;
}

inline bool in_bounds(const Vector3i &p, const Vector3i &size)
{
    return (p.x >= 0 && p.x < size.x && p.y >= 0 && p.y < size.y && p.z >= 0 && p.z < size.z);
}

inline float safe_log(float x)
{
    return std::log(std::max(x, EPS));
}

inline float biased_entropy(const std::array<float, T> &p)
{
    constexpr float w_air = 0.1f; // Air is "less interesting"
    float weighted_sum = 0.0f;
    std::array<float, T> p_adj;

    for (int i = 0; i < T; ++i)
    {
        float w = (i == 0) ? w_air : 1.0f;
        p_adj[i] = p[i] * w;
        weighted_sum += p_adj[i];
    }

    // normalise adjusted probs
    for (int i = 0; i < T; ++i)
        p_adj[i] /= weighted_sum;

    // Shannon entropy on adjusted probs
    float H = 0.0f;
    for (int i = 0; i < T; ++i)
    {
        float pi = p_adj[i];
        if (pi > 0.0f)
            H -= pi * safe_log(pi);
    }
    return H;
}

inline float shannon_entropy(const std::array<float, T> &p)
{
    // return biased_entropy(p);
    float H = 0.0f;
    for (int i = 0; i < T; ++i)
    {
        float pi = p[i];
        if (pi > 0.0f)
            H -= pi * safe_log(pi);
    }
    return H;
}

// Normalize vector; returns sum before normalization
inline float normalize(std::array<float, T> &p)
{
    float s = 0.0f;
    for (int i = 0; i < T; ++i)
        s += p[i];
    if (s <= 0.0f)
        return 0.0f;
    float inv = 1.0f / s;
    for (int i = 0; i < T; ++i)
        p[i] *= inv;
    return s;
}

// Weighted sample from p (assumed normalized)
inline int weighted_sample(const std::array<float, T> &p, std::mt19937 &rng)
{
    std::uniform_real_distribution<float> dist(0.0f, 1.0f);
    float r = dist(rng);
    float cum = 0.0f;
    for (int i = 0; i < T; ++i)
    {
        cum += p[i];
        if (r <= cum)
            return i;
    }
    // Fallback in case of FP rounding
    for (int i = T - 1; i >= 0; --i)
        if (p[i] > 0.0f)
            return i;
    return 0;
}

} // namespace

struct WFCModel
{
    // P(center=j | neighbor type t, offset k) or the transpose you prefer
    std::vector<std::array<std::array<float, T>, T>> probabilities{};
    std::array<float, T> priors{};
    const Neighborhood &ngh;

    WFCModel(const Neighborhood &ngh) : ngh(ngh)
    {
        probabilities.resize(ngh.get_K());
    }

    void debug_print(float epsilon = 1e-8f) const
    {
        String s = "Priors (non-zero):\n";
        for (int i = 0; i < T; ++i)
        {
            float p = priors[i];
            if (p > epsilon)
            {
                s += String::num_int64(i) + ": " + String::num(p, 6) + "\n";
            }
        }
        UtilityFunctions::print(s);

        for (int d = 0; d < ngh.get_K(); ++d)
        {
            String block;
            auto offset = ngh.offsets()[d];
            String dir = "(" + String::num_int64(offset.x) + "," + String::num_int64(offset.y) + "," +
                         String::num_int64(offset.z) + ")";
            block += "Dir " + dir + " adjacency (non-zero):\n";
            for (int i = 0; i < T; ++i)
            {
                String line;
                bool any = false;
                for (int j = 0; j < T; ++j)
                {
                    float p = probabilities[d][i][j];
                    if (p > epsilon)
                    {
                        if (!any)
                        {
                            line = String::num_int64(i) + " -> ";
                            any = true;
                        }
                        else
                        {
                            line += String(", ");
                        }
                        line += String::num_int64(j) + ": " + String::num(p, 6);
                    }
                }
                if (any)
                {
                    block += line + "\n";
                }
            }
            UtilityFunctions::print(block);
        }
    }
};

WFCModel build_model_from_voxels(const Ref<VoxelDataVox> voxel_data, const Vector3i &size, const Neighborhood &ngh,
                                 bool use_alpha, float alpha)
{
    WFCModel model = WFCModel(ngh);
    std::vector<std::array<std::array<uint32_t, T>, T>> counts{};
    counts.resize(ngh.get_K());
    std::array<uint32_t, T> prior_counts{};

    auto idx3 = [&](int x, int y, int z) { return z * (size.x * size.y) + y * size.x + x; };

    for (int z = 0; z < size.z; ++z)
        for (int y = 0; y < size.y; ++y)
            for (int x = 0; x < size.x; ++x)
            {
                uint8_t center = voxel_data->get_voxel_palette_index_at(Vector3i(x, y, z));
                Voxel center_voxel = voxel_data->get_voxel_at(Vector3i(x, y, z));
                prior_counts[center]++;

                if (voxel_to_palette_index.find(center_voxel) == voxel_to_palette_index.end())
                {
                    voxel_to_palette_index[center_voxel] = center;
                }

                const auto &offs = ngh.offsets();
                for (int k = 0; k < ngh.get_K(); ++k)
                {
                    Vector3i o = offs[k];
                    int nx = x + o.x, ny = y + o.y, nz = z + o.z;
                    if (nx < 0 || ny < 0 || nz < 0 || nx >= size.x || ny >= size.y || nz >= size.z)
                        continue;
                    uint8_t neigh = voxel_data->get_voxel_palette_index_at(Vector3i(nx, ny, nz));
                    // counts[k][neighbor_type][center_type] or vice versa — be consistent with apply step
                    counts[k][neigh][center]++; // example: row=neigh type, col=center type
                }
            }

    // Priors with optional alpha
    double tot = 0.0;
    for (int t = 0; t < T; ++t)
    {
        double v = prior_counts[t] + (use_alpha ? alpha : 0.0);
        model.priors[t] = float(v);
        tot += v;
    }
    if (tot > 0)
        for (int t = 0; t < T; ++t)
            model.priors[t] /= float(tot);
    else
        for (int t = 0; t < T; ++t)
            model.priors[t] = 1.0f / T;

    // Normalize conditionals per k, per neighbor type row
    for (int k = 0; k < ngh.get_K(); ++k)
    {
        for (int neigh = 0; neigh < T; ++neigh)
        {
            bool use_binary_mask = true;
            double row_sum = 0.0;
            for (int center = 0; center < T; ++center)
            {
                double v = counts[k][neigh][center] + (use_alpha ? alpha : 0.0);
                if (use_binary_mask)
                    v = v > 0.01f ? 1.0f : 0.0f;
                model.probabilities[k][neigh][center] = float(v);
                row_sum += v;
            }
            if (row_sum > 0 && !use_binary_mask)
            {
                float inv = float(1.0 / row_sum);
                for (int center = 0; center < T; ++center)
                    model.probabilities[k][neigh][center] *= inv;
            }
            // else
            // {
            //     // fallback to priors if no observations
            //     for (int center = 0; center < T; ++center)
            //         model.probabilities[k][neigh][center] = 0; // model.priors[center];
            // }
        }
    }

    return model;
}

bool VoxelWorldWFCAdjacencyGenerator::generate(std::vector<Voxel> &result_voxels, const Vector3i bounds_min,
                                               const Vector3i bounds_max, const VoxelWorldProperties &properties)
{
    // todo integrate this

    if (voxel_data.is_null())
    {
        UtilityFunctions::printerr("Voxel data is not set for WFC generator.");
        return false;
    }
    voxel_data->load();

    // Decide output size
    Vector3i out_size = bounds_max - bounds_min;
    auto grid_size = target_grid_size.min(out_size);

    Vector3i training_size = voxel_data->get_size();

    const bool use_alpha = false;
    const float alpha = 0.25;

    std::unique_ptr<NeighborhoodBase> ngh = std::make_unique<Moore>(neighborhood_radius, use_exhaustive_offsets);

    switch (neighborhood_type)
    {
    case NEIGHBORHOOD_VON_NEUMANN:
        ngh = std::make_unique<VonNeumann>(neighborhood_radius, use_exhaustive_offsets);
        break;
    default:
        break;
    }

    const int K = ngh->get_K();

    auto model = build_model_from_voxels(voxel_data, training_size, *ngh, use_alpha, alpha);
    model.debug_print();

    // Initialize RNG
    std::mt19937 rng(Time::get_singleton()->get_unix_time_from_system());

    // Grid of polymorphic cells
    const int N = grid_size.x * grid_size.y * grid_size.z;
    std::vector<std::unique_ptr<WFCVoxel>> grid;
    grid.reserve(N);
    for (int i = 0; i < N; ++i)
        grid.emplace_back(std::make_unique<EmptyVoxel>());

    auto get = [&](int idx) -> WFCVoxel * { return grid[idx].get(); };

    // 3) Min-heap with explicit comparator
    struct HeapNode
    {
        float entropy;
        int index;
        uint32_t version;
    };
    struct HeapCompare
    {
        bool operator()(const HeapNode &a, const HeapNode &b) const
        {
            return a.entropy > b.entropy; // min-heap
        }
    };
    std::priority_queue<HeapNode, std::vector<HeapNode>, HeapCompare> heap;
    std::deque<int> wave_q;
    std::vector<uint8_t> in_wave, dirty;
    std::vector<int> pending_heap;
    in_wave.assign(N, 0);
    dirty.assign(N, 0);
    pending_heap.reserve(128);

    // 4) Helpers
    auto make_superposition = [&](int idx) -> SuperpositionVoxel * {
        auto sp = std::make_unique<SuperpositionVoxel>();
        for (int j = 1; j < T; ++j)
            sp->p[j] = model.priors[j];
        sp->p[0] = 0.0f;
        normalize(sp->p);
        sp->entropy = shannon_entropy(sp->p);
        sp->version = 0;
        auto *raw = sp.get();
        grid[idx] = std::move(sp);
        return raw;
    };

    auto collapse_to_type = [&](int idx, uint8_t t, bool is_debug) {
        auto cv = std::make_unique<CollapsedVoxel>();
        cv->type = t;
        cv->is_debug = is_debug;
        grid[idx] = std::move(cv);
    };

    auto pos_from_index = [&](int idx) -> Vector3i {
        int x = idx % grid_size.x;
        int y = (idx / grid_size.x) % grid_size.y;
        int z = idx / (grid_size.x * grid_size.y);
        return Vector3i(x, y, z);
    };

    // NOTE:
    // We may be using the transpose to the adjacency matrix, but if we don't the world is upside down...

    auto init_from_single_neighbor = [&](int target_idx, const WFCModel &model, int dir_to_neighbor,
                                         uint8_t neighbor_type, float weight) -> SuperpositionVoxel * {
        auto sp = std::make_unique<SuperpositionVoxel>();
        for (int j = 0; j < T; ++j)
            sp->p[j] = model.priors[j] * std::pow(model.probabilities[dir_to_neighbor][j][neighbor_type], weight);

        if (normalize(sp->p) <= 0.0f)
        {
            collapse_to_type(target_idx, DEBUG_TILE_ID, true); // contradiction marker
            return nullptr;
        }
        sp->entropy = shannon_entropy(sp->p);
        sp->version = 0;
        auto *raw = sp.get();
        grid[target_idx] = std::move(sp);
        return raw;
    };

    // Pass the index in — no pointer arithmetic
    auto update_from_neighbor = [&](int idx, SuperpositionVoxel &tgt, const WFCModel &model, int dir_to_neighbor,
                                    uint8_t neighbor_type, float weight) -> bool {
        for (int j = 0; j < T; ++j)
            tgt.p[j] *= std::pow(model.probabilities[dir_to_neighbor][j][neighbor_type], weight);

        if (normalize(tgt.p) <= 0.0f)
        {
            collapse_to_type(idx, DEBUG_TILE_ID, true);
            return false;
        }
        tgt.entropy = shannon_entropy(tgt.p);
        tgt.version += 1;
        return true;
    };

    // Mixture from a source superposition p_src onto direction k
    auto build_mixture = [&](int k, const std::array<float, T> &p_src, std::array<float, T> &mix_out) {
        // mix_out[j] = sum_t p_src[t] * probabilities[k][t][j]
        for (int j = 0; j < T; ++j)
            mix_out[j] = 0.0f;
        for (int t = 0; t < T; ++t)
        {
            float wt = p_src[t];
            if (wt <= 0.0f)
                continue;
            const auto &row = model.probabilities[k][t];
            for (int j = 0; j < T; ++j)
                mix_out[j] += wt * row[j];
        }
        // No normalization here; we multiply and then normalize target
    };

    // Apply a floating mask to target; returns changed/contradiction flag
    auto apply_mix_to_target = [&](int idx, SuperpositionVoxel &tgt, const std::array<float, T> &mix) -> bool {
        bool any = false;
        for (int j = 0; j < T; ++j)
        {
            float before = tgt.p[j];
            float after = before * mix[j];
            if (after != before)
                any = true;
            tgt.p[j] = after;
        }
        if (normalize(tgt.p) <= 0.0f)
        {
            collapse_to_type(idx, DEBUG_TILE_ID, true);
            return true;
        }
        if (any)
        {
            tgt.entropy = shannon_entropy(tgt.p);
            tgt.version += 1;
        }
        return any;
    };

    // --- Optional: bootstrap from an initial generator pass ---
    bool bootstrapped = false;
    bool created_any_superposition = false;

    if (initial_state.is_valid())
    {
        std::vector<Voxel> initial_voxels(result_voxels.size(), Voxel::create_air_voxel());
        if (initial_state->generate(initial_voxels, bounds_min, bounds_max, properties))
        {

            auto get_initial_at_world = [&](const Vector3i &wp) -> Voxel {
                int idx = properties.pos_to_voxel_index(wp);
                if (idx < 0 || idx >= (int)initial_voxels.size())
                    return Voxel::create_air_voxel();
                return initial_voxels[idx];
            };

            std::vector<int> collapsed_indices;
            std::vector<uint8_t> collapsed_types;
            collapsed_indices.reserve(N);
            collapsed_types.reserve(N);

            // Collapse all non-air directly to their type
            for (int i = 0; i < N; ++i)
            {
                Voxel v = get_initial_at_world(pos_from_index(i) + bounds_min);
                uint8_t t = 0;
                if (voxel_to_palette_index.find(v) == voxel_to_palette_index.end())
                {
                    t = voxel_to_palette_index[v];
                }

                if (t == 0)
                    continue; // leave air as EMPTY
                collapse_to_type(i, t, /*debug*/ false);
                collapsed_indices.push_back(i);
                collapsed_types.push_back(t);
            }

            // Propagate constraints from collapsed cells
            const auto &offs = ngh->offsets();
            const int K = ngh->get_K();
            for (size_t c = 0; c < collapsed_indices.size(); ++c)
            {
                int idx = collapsed_indices[c];
                uint8_t t = collapsed_types[c];
                Vector3i pos = pos_from_index(idx);

                for (int k = 0; k < K; ++k)
                {
                    Vector3i np = pos + offs[k];
                    if (!in_bounds(np, grid_size))
                        continue;
                    int nidx = index_3d(np, grid_size);

                    if (grid[nidx]->kind() == WFCVoxel::Kind::EMPTY)
                    {
                        if (auto *tgt = init_from_single_neighbor(nidx, model, k, t, /*w*/ 1.0f))
                        {
                            created_any_superposition = true;
                            heap.push({tgt->entropy, nidx, tgt->version});
                        }
                    }
                    else if (grid[nidx]->kind() == WFCVoxel::Kind::SUPERPOSITION)
                    {
                        auto *tgt = static_cast<SuperpositionVoxel *>(grid[nidx].get());
                        if (update_from_neighbor(nidx, *tgt, model, k, t, /*w*/ 1.0f))
                        {
                            heap.push({tgt->entropy, nidx, tgt->version});
                        }
                    }
                }
            }

            bootstrapped = true;
        }
    }

    // If nothing was created by the bootstrap, seed entropy as before
    if (!bootstrapped || !created_any_superposition)
    {
        int seed_idx = index_3d((seed_position_normalized * grid_size).floor(), grid_size);
        SuperpositionVoxel *seed_sp = make_superposition(seed_idx);
        heap.push({seed_sp->entropy, seed_idx, seed_sp->version});
    }

    const auto &offs = ngh->offsets();

    // 6) Main loop
    while (!heap.empty())
    {
        HeapNode node = heap.top();
        heap.pop();
        if (grid[node.index]->kind() != WFCVoxel::Kind::SUPERPOSITION)
            continue;
        auto *sp = static_cast<SuperpositionVoxel *>(grid[node.index].get());
        if (sp->version != node.version)
            continue; // stale

        // Collapse
        int t = weighted_sample(sp->p, rng);
        collapse_to_type(node.index, static_cast<uint8_t>(t), false);

        // Seed neighbors into wave if they changed/created
        if (!in_wave[node.index])
        {
            wave_q.push_back(node.index);
            in_wave[node.index] = 1;
        }

        // Neighbors
        Vector3i pos = pos_from_index(node.index);
        for (int k = 0; k < K; ++k)
        {
            Vector3i np = pos + offs[k];
            if (!in_bounds(np, grid_size))
                continue;
            int nidx = index_3d(np, grid_size);
            float w = 1.0; // ngh.weight_for_offset(k);

            if (grid[nidx]->kind() == WFCVoxel::Kind::EMPTY)
            {
                if (auto *tgt = init_from_single_neighbor(nidx, model, k, t, w))
                    heap.push({tgt->entropy, nidx, tgt->version});
            }
            else if (grid[nidx]->kind() == WFCVoxel::Kind::SUPERPOSITION)
            {
                auto *tgt = static_cast<SuperpositionVoxel *>(grid[nidx].get());
                if (update_from_neighbor(nidx, *tgt, model, k, t, w))
                {
                    // tgt->entropy = shannon_entropy(tgt->p);
                    // tgt->version += 1;
                    heap.push({tgt->entropy, nidx, tgt->version});
                }
            }
        }

        if (enable_superposition_propagation)
        {
            std::array<float, T> mix;
            while (!wave_q.empty())
            {
                int src_idx = wave_q.front();
                wave_q.pop_front();
                in_wave[src_idx] = 0;

                // Source can be collapsed or superposition
                Vector3i spos = pos_from_index(src_idx);
                bool src_is_sp = (grid[src_idx]->kind() == WFCVoxel::Kind::SUPERPOSITION);
                int src_type = -1;
                const std::array<float, T> *src_p = nullptr;

                if (src_is_sp)
                {
                    auto *src_sp = static_cast<SuperpositionVoxel *>(grid[src_idx].get());
                    src_p = &src_sp->p;
                    // If it’s degenerate (nearly one-hot), treat as collapsed fast-path
                    // Detect single non-zero bin
                    int count = 0, last = -1;
                    for (int t = 0; t < T; ++t)
                        if (src_sp->p[t] > 0.0f)
                        {
                            count++;
                            last = t;
                            if (count > 1)
                                break;
                        }
                    if (count == 1)
                    {
                        src_is_sp = false;
                        src_type = last;
                    }
                }
                else if (grid[src_idx]->kind() == WFCVoxel::Kind::COLLAPSED)
                {
                    auto *src_cl = static_cast<CollapsedVoxel *>(grid[src_idx].get());
                    src_type = src_cl->type;
                }
                else
                {
                    continue;
                }

                for (int k = 0; k < K; ++k)
                {
                    Vector3i np = spos + offs[k];
                    if (!in_bounds(np, grid_size))
                        continue;
                    int nidx = index_3d(np, grid_size);

                    if (grid[nidx]->kind() != WFCVoxel::Kind::SUPERPOSITION)
                        continue;
                    auto *tgt = static_cast<SuperpositionVoxel *>(grid[nidx].get());

                    bool changed = false;
                    if (src_type >= 0)
                    {
                        // collapsed neighbor: multiply by conditional row
                        for (int j = 0; j < T; ++j)
                        {
                            float before = tgt->p[j];
                            float after = before * model.probabilities[k][src_type][j];
                            if (after != before)
                                changed = true;
                            tgt->p[j] = after;
                        }
                        if (normalize(tgt->p) <= 0.0f)
                        {
                            collapse_to_type(nidx, DEBUG_TILE_ID, true);
                            dirty[nidx] = 1;
                            continue;
                        }
                        if (changed)
                        {
                            tgt->entropy = shannon_entropy(tgt->p);
                            tgt->version += 1;
                        }
                    }
                    else
                    {
                        // superposition neighbor: build mixture and apply
                        build_mixture(k, *src_p, mix);
                        changed = apply_mix_to_target(nidx, *tgt, mix);
                    }

                    if (changed)
                    {
                        dirty[nidx] = 1;
                        if (!in_wave[nidx])
                        {
                            wave_q.push_back(nidx);
                            in_wave[nidx] = 1;
                        }
                    }
                }
            }

            // Batch-push changed nodes after wave settles
            pending_heap.clear();
            for (int i = 0; i < N; ++i)
            {
                if (!dirty[i])
                    continue;
                dirty[i] = 0;
                if (grid[i]->kind() != WFCVoxel::Kind::SUPERPOSITION)
                    continue;
                auto *t = static_cast<SuperpositionVoxel *>(grid[i].get());
                pending_heap.push_back(i);
            }
            for (int idx : pending_heap)
            {
                auto *t = static_cast<SuperpositionVoxel *>(grid[idx].get());
                heap.push({t->entropy, idx, t->version});
            }
        }
    }

    for (int i = 0; i < N; ++i)
    {
        // TODO maybe add offsets/scale depending on what we want.
        int result_idx = properties.pos_to_voxel_index(pos_from_index(i) + bounds_min);
        if (result_idx < 0 || result_idx >= result_voxels.size())
            continue;

        if (!grid[i] || (!result_voxels[result_idx].is_air() && only_replace_air))
            continue;

        if (grid[i]->kind() == WFCVoxel::Kind::COLLAPSED)
        {
            auto *cv = static_cast<CollapsedVoxel *>(grid[i].get());
            uint8_t id = cv->type;
            // If debug, use a special magenta tile
            if (cv->is_debug)
            {
                if (show_contradictions)
                    result_voxels[result_idx] = Voxel::create_voxel(DEBUG_TILE_ID, Color(1.0f, 0.0f, 1.0f));
            }
            else if (id > 0)
            {
                result_voxels[result_idx] =
                    Voxel::create_voxel(Voxel::VOXEL_TYPE_SOLID, voxel_data->get_palette()[id - 1]);
            }
        }
    }

    return true;
    // voxel_world_rids.set_voxel_data(result_voxels);
}
