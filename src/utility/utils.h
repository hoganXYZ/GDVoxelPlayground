#ifndef UTILS_H
#define UTILS_H

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/random_number_generator.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <vector>

namespace godot
{

class Utils : public Object
{
    GDCLASS(Utils, Object);

  public:
    Utils()
    {
    }
    ~Utils()
    {
    }
    static PackedFloat32Array vector_to_array_float(const std::vector<float> &vec)
    {
        PackedFloat32Array array;
        array.resize(vec.size());
        std::copy(vec.begin(), vec.end(), array.ptrw());
        return array;
    }

    static std::vector<float> array_to_vector_float(const PackedFloat32Array &array)
    {
        std::vector<float> vec(array.size());
        std::copy(array.ptr(), array.ptr() + array.size(), vec.begin());
        return vec;
    }

    static PackedInt32Array vector_to_array_int(const std::vector<int> &vec)
    {
        PackedInt32Array array;
        array.resize(vec.size());
        std::copy(vec.begin(), vec.end(), array.ptrw());
        return array;
    }

    static std::vector<int> array_to_vector_int(const PackedInt32Array &array)
    {
        std::vector<int> vec(array.size());
        std::copy(array.ptr(), array.ptr() + array.size(), vec.begin());
        return vec;
    }

    static godot::String vector_to_string_float(const std::vector<float> &vec)
    {
        godot::String string = "[";
        for (const float &f : vec)
        {
            string += String::num(f, 2) + ", ";
        }
        return string + "]";
    }

    // template <class matType> static godot::String to_string(const matType &v)
    // {
    //     return godot::String(("{" + glm::to_string(v) + "}").c_str());
    // }

    static void print_projection(Projection projection)
    {
        String str = "Projection:\n";
        for (int i = 0; i < 4; i++)
        {
            str += String::num(projection[i].x) + ", " + String::num(projection[i].y) + ", " +
                   String::num(projection[i].z) + ", " + String::num(projection[i].w) + "\n";
        }
        UtilityFunctions::print(str);
    }

    static inline void projection_to_float(float *target, const Projection &t)
    {
        for (size_t i = 0; i < 4; i++)
        {
            target[i * 4] = t.columns[i].x;
            target[i * 4 + 1] = t.columns[i].y;
            target[i * 4 + 2] = t.columns[i].z;
            target[i * 4 + 3] = t.columns[i].w;
        }
    }

    static inline void projection_to_float_transposed(float *target, const Projection &t)
    {
        for (size_t i = 0; i < 4; i++)
        {
            target[i * 4] = t.columns[0][i];
            target[i * 4 + 1] = t.columns[1][i];
            target[i * 4 + 2] = t.columns[2][i];
            target[i * 4 + 3] = t.columns[3][i];
        }
    }

    static inline unsigned int compress_color16(Color rgb)
    {

        // H: 7 bits, S: 4 bits, V: 5 bits
        unsigned int h = static_cast<unsigned int>(rgb.get_h() * 127.0);
        unsigned int s = static_cast<unsigned int>(rgb.get_s() * 15.0);
        unsigned int v = static_cast<unsigned int>(rgb.get_v() * 31.0);

        // Pack into a single unsigned int
        return (h << 9) | (s << 5) | v;
    }

    static inline Color decompress_color16(unsigned int packedColor)
    {
        // Extract H, S, V components
        unsigned int h = (packedColor >> 9) & 0x7F; // 7 bits for hue
        unsigned int s = (packedColor >> 5) & 0x0F; // 4 bits for saturation
        unsigned int v = packedColor & 0x1F;        // 5 bits for value

        // Convert back to RGB
        return Color::from_hsv(float(h) / 128.0, float(s) / 16.0, float(v) / 32.0);
    }

    static Ref<RandomNumberGenerator> rng;

    // sRGB → linear
    static inline float srgb_to_linear(float c)
    {
        return c <= 0.04045f ? c / 12.92f : powf((c + 0.055f) / 1.055f, 2.4f);
    }

    // linear → sRGB
    static inline float linear_to_srgb(float c)
    {
        return c <= 0.0031308f ? 12.92f * c : 1.055f * powf(c, 1.0f / 2.4f) - 0.055f;
    }

    // Convert sRGB Color to OKLab (L, a, b)
    static inline void rgb_to_oklab(Color rgb, float &L, float &a, float &b)
    {
        float r = srgb_to_linear(rgb.r);
        float g = srgb_to_linear(rgb.g);
        float bl = srgb_to_linear(rgb.b);

        float l_ = 0.4122214708f * r + 0.5363325363f * g + 0.0514459929f * bl;
        float m_ = 0.2119034982f * r + 0.6806995451f * g + 0.1073969566f * bl;
        float s_ = 0.0883024619f * r + 0.2817188376f * g + 0.6299787005f * bl;

        l_ = cbrtf(l_); m_ = cbrtf(m_); s_ = cbrtf(s_);

        L = 0.2104542553f * l_ + 0.7936177850f * m_ - 0.0040720468f * s_;
        a = 1.9779984951f * l_ - 2.4285922050f * m_ + 0.4505937099f * s_;
        b = 0.0259040371f * l_ + 0.7827717662f * m_ - 0.8086757660f * s_;
    }

    // Convert OKLab (L, a, b) to sRGB Color
    static inline Color oklab_to_rgb(float L, float a, float b)
    {
        float l_ = L + 0.3963377774f * a + 0.2158037573f * b;
        float m_ = L - 0.1055613458f * a - 0.0638541728f * b;
        float s_ = L - 0.0894841775f * a - 1.2914855480f * b;

        float l = l_ * l_ * l_;
        float m = m_ * m_ * m_;
        float s = s_ * s_ * s_;

        float r = +4.0767416621f * l - 3.3077115913f * m + 0.2309699292f * s;
        float g = -1.2684380046f * l + 2.6097574011f * m - 0.3413193965f * s;
        float bl = -0.0041960863f * l - 0.7034186147f * m + 1.7076147010f * s;

        return Color(
            Math::clamp(linear_to_srgb(r), 0.0f, 1.0f),
            Math::clamp(linear_to_srgb(g), 0.0f, 1.0f),
            Math::clamp(linear_to_srgb(bl), 0.0f, 1.0f));
    }

    static Color randomized_color(Color color)
    {
        Vector3 hsv = {color.get_h(), color.get_s(), color.get_v()};
        // Math::randf
        if (!rng.is_valid())
        {
            rng.instantiate();
            rng->set_seed(Time::get_singleton()->get_unix_time_from_system());
        }

        hsv.x = Math::clamp(hsv.x + rng->randf() * 0.025f, 0.0f, 1.0f);
        hsv.y = Math::clamp(hsv.y *(0.95f + rng->randf() * 0.1f), 0.0f, 1.0f);
        hsv.z = Math::clamp(hsv.z *(0.95f + rng->randf() * 0.1f), 0.0f, 1.0f);

        return Color::from_hsv(hsv.x, hsv.y, hsv.z);
    }
};

} // namespace godot

#endif
