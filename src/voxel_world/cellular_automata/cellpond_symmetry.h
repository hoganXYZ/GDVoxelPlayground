#ifndef CELLPOND_SYMMETRY_H
#define CELLPOND_SYMMETRY_H

#include "cellpond_rule.h"
#include <array>
#include <vector>
#include <set>

namespace godot
{

// A 3x3 integer rotation matrix (row-major)
struct RotationMatrix
{
    int m[3][3];

    void apply(int8_t ix, int8_t iy, int8_t iz, int8_t &ox, int8_t &oy, int8_t &oz) const
    {
        ox = static_cast<int8_t>(m[0][0] * ix + m[0][1] * iy + m[0][2] * iz);
        oy = static_cast<int8_t>(m[1][0] * ix + m[1][1] * iy + m[1][2] * iz);
        oz = static_cast<int8_t>(m[2][0] * ix + m[2][1] * iy + m[2][2] * iz);
    }

    // Multiply two rotation matrices: result = this * other
    RotationMatrix operator*(const RotationMatrix &other) const
    {
        RotationMatrix result;
        for (int i = 0; i < 3; i++)
            for (int j = 0; j < 3; j++)
            {
                result.m[i][j] = 0;
                for (int k = 0; k < 3; k++)
                    result.m[i][j] += m[i][k] * other.m[k][j];
            }
        return result;
    }

    bool operator<(const RotationMatrix &other) const
    {
        for (int i = 0; i < 3; i++)
            for (int j = 0; j < 3; j++)
            {
                if (m[i][j] < other.m[i][j]) return true;
                if (m[i][j] > other.m[i][j]) return false;
            }
        return false;
    }

    bool operator==(const RotationMatrix &other) const
    {
        for (int i = 0; i < 3; i++)
            for (int j = 0; j < 3; j++)
                if (m[i][j] != other.m[i][j]) return false;
        return true;
    }
};

// Generate all 24 proper rotations of a cube by composing generators.
// R_y90: (x,y,z) -> (z, y, -x)
// R_x90: (x,y,z) -> (x, -z, y)
inline std::vector<RotationMatrix> generate_cube_rotations()
{
    static const RotationMatrix R_Y90 = {{{ 0, 0, 1}, { 0, 1, 0}, {-1, 0, 0}}};
    static const RotationMatrix R_X90 = {{{ 1, 0, 0}, { 0, 0,-1}, { 0, 1, 0}}};
    static const RotationMatrix IDENTITY = {{{ 1, 0, 0}, { 0, 1, 0}, { 0, 0, 1}}};

    std::set<RotationMatrix> found;
    std::vector<RotationMatrix> queue;
    queue.push_back(IDENTITY);
    found.insert(IDENTITY);

    // BFS: apply R_Y90 and R_X90 to every known rotation until we have all 24
    size_t head = 0;
    while (head < queue.size() && found.size() < 24)
    {
        RotationMatrix current = queue[head++];
        RotationMatrix candidates[2] = {current * R_Y90, current * R_X90};
        for (int i = 0; i < 2; i++)
        {
            if (found.find(candidates[i]) == found.end())
            {
                found.insert(candidates[i]);
                queue.push_back(candidates[i]);
            }
        }
    }

    return queue;
}

// Singleton-style access to the 24 rotations (generated once)
inline const std::vector<RotationMatrix> &get_all_cube_rotations()
{
    static std::vector<RotationMatrix> rotations = generate_cube_rotations();
    return rotations;
}

// Get the rotation matrices for a given symmetry mode
inline std::vector<RotationMatrix> get_symmetry_rotations(int symmetry_mode)
{
    const auto &all = get_all_cube_rotations();
    std::vector<RotationMatrix> result;

    switch (symmetry_mode)
    {
    case CELLPOND_SYMMETRY_NONE:
        result.push_back(all[0]); // identity only
        break;

    case CELLPOND_SYMMETRY_ROTATE_Y4:
    {
        // 4 rotations around Y axis: identity, Y90, Y180, Y270
        static const RotationMatrix R_Y90 = {{{ 0, 0, 1}, { 0, 1, 0}, {-1, 0, 0}}};
        RotationMatrix current = {{{ 1, 0, 0}, { 0, 1, 0}, { 0, 0, 1}}};
        for (int i = 0; i < 4; i++)
        {
            result.push_back(current);
            current = current * R_Y90;
        }
        break;
    }

    case CELLPOND_SYMMETRY_ROTATE_ALL24:
        result = all;
        break;

    case CELLPOND_SYMMETRY_FULL48:
        // All 24 rotations; reflections are handled in the expansion step
        // by generating a second set with all offsets negated
        result = all;
        break;

    default:
        result.push_back(all[0]);
        break;
    }

    return result;
}

// Apply a rotation to a pattern entry, returning the transformed entry
inline CellPondPatternEntry transform_pattern_entry(const CellPondPatternEntry &entry, const RotationMatrix &rot)
{
    CellPondPatternEntry result = entry;
    rot.apply(entry.dx, entry.dy, entry.dz, result.dx, result.dy, result.dz);
    return result;
}

// Apply a rotation to a result entry, returning the transformed entry
inline CellPondResultEntry transform_result_entry(const CellPondResultEntry &entry, const RotationMatrix &rot)
{
    CellPondResultEntry result = entry;
    rot.apply(entry.dx, entry.dy, entry.dz, result.dx, result.dy, result.dz);
    return result;
}

} // namespace godot

#endif // CELLPOND_SYMMETRY_H
