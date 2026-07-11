#ifndef DEBUG_PRINT_GLSL
#define DEBUG_PRINT_GLSL

// ============================================================================
// GPU Debug Print — on-screen text overlay for shader debugging
//
// Usage:
//   #include "debug_print.glsl.inc"
//
//   // After computing scene color, before imageStore:
//   float bg = debugBg(pos, 3);
//   if (bg > 0.0) color.rgb *= 0.3;
//
//   float dbg = 0.0;
//   dbg += debugFloat(pos, 0, someVar);
//   dbg += debugVec3(pos, 1, position);
//   dbg += debugUint(pos, 2, voxel.data);
//   if (dbg > 0.0) color = vec3(1.0);
//
//   imageStore(outputImage, pos, vec4(color, 1.0));
// ============================================================================

// Configuration — #define these before #include to override
#ifndef DEBUG_SCALE
#define DEBUG_SCALE 2
#endif

#ifndef DEBUG_ORIGIN
#define DEBUG_ORIGIN ivec2(8, 8)
#endif

#ifndef DEBUG_INT_DIGITS
#define DEBUG_INT_DIGITS 6
#endif

#ifndef DEBUG_FRAC_DIGITS
#define DEBUG_FRAC_DIGITS 3
#endif

// ============================================================================
// Internal constants
// ============================================================================

const int _DC_MINUS = 10;
const int _DC_DOT   = 11;
const int _DC_SPACE = 12;
const int _DC_A     = 13;
const int _DC_COLON = 19;
const int _DC_X     = 20;
const int _DC_I     = 21;
const int _DC_N     = 22;

const int _CHAR_W = 4;
const int _CHAR_H = 5;
const int _CHAR_GAP_X = 1;
const int _CHAR_GAP_Y = 2;

// 4x5 bitmap font — 20 bits per character packed in a uint
// Bit 19 = top-left, bit 0 = bottom-right
const uint _DEBUG_FONT[23] = uint[23](
    0x69996u, // 0  .##. #..# #..# #..# .##.
    0x26227u, // 1  ..#. .##. ..#. ..#. .###
    0x6924Fu, // 2  .##. #..# ..#. .#.. ####
    0x69296u, // 3  .##. #..# ..#. #..# .##.
    0x99F11u, // 4  #..# #..# #### ...# ...#
    0xF8E1Eu, // 5  #### #... ###. ...# ###.
    0x68E96u, // 6  .##. #... ###. #..# .##.
    0xF1244u, // 7  #### ...# ..#. .#.. .#..
    0x69696u, // 8  .##. #..# .##. #..# .##.
    0x69716u, // 9  .##. #..# .### ...# .##.
    0x00F00u, // -  .... .... #### .... ....
    0x00066u, // .  .... .... .... .##. .##.
    0x00000u, //    (space)
    0x69F99u, // A  .##. #..# #### #..# #..#
    0xE9E9Eu, // B  ###. #..# ###. #..# ###.
    0x78887u, // C  .### #... #... #... .###
    0xE999Eu, // D  ###. #..# #..# #..# ###.
    0xF8E8Fu, // E  #### #... ###. #... ####
    0xF8E88u, // F  #### #... ###. #... #...
    0x06060u, // :  .... .##. .... .##. ....
    0x09690u, // x  .... #..# .##. #..# ....
    0x72227u, // I  .### ..#. ..#. ..#. .###
    0x9DB99u  // N  #..# ##.# #.## #..# #..#
);

// ============================================================================
// Internal helpers
// ============================================================================

float _debugCharPixel(int code, ivec2 p) {
    if (code < 0 || code > 22) return 0.0;
    uint bitmap = _DEBUG_FONT[code];
    int bitIdx = 19 - (p.y * 4 + p.x);
    return float((bitmap >> bitIdx) & 1u);
}

ivec2 _debugLineOrigin(int line) {
    int cellH = (_CHAR_H + _CHAR_GAP_Y) * DEBUG_SCALE;
    return DEBUG_ORIGIN + ivec2(0, line * cellH);
}

int _debugFloatChars(int fracDigits) {
    return 1 + DEBUG_INT_DIGITS + (fracDigits > 0 ? 1 + fracDigits : 0);
}

float _debugRenderChars(ivec2 pixel, ivec2 origin, int c0, int c1, int c2, int c3, int count) {
    int cellW = (_CHAR_W + _CHAR_GAP_X) * DEBUG_SCALE;
    ivec2 p = pixel - origin;
    if (p.y < 0 || p.y >= _CHAR_H * DEBUG_SCALE) return 0.0;
    if (p.x < 0 || p.x >= count * cellW) return 0.0;

    int charIdx = p.x / cellW;
    int cx = (p.x % cellW) / DEBUG_SCALE;
    int cy = p.y / DEBUG_SCALE;
    if (cx >= _CHAR_W) return 0.0;

    int charCode = charIdx == 0 ? c0 : charIdx == 1 ? c1 : charIdx == 2 ? c2 : c3;
    return _debugCharPixel(charCode, ivec2(cx, cy));
}

float _debugRenderFloat(ivec2 pixel, ivec2 origin, float value, int intDigits, int fracDigits) {
    // NaN
    if (isnan(value)) {
        return _debugRenderChars(pixel, origin, _DC_N, _DC_A, _DC_N, _DC_SPACE, 3);
    }
    // Inf
    if (isinf(value)) {
        if (value < 0.0)
            return _debugRenderChars(pixel, origin, _DC_MINUS, _DC_I, _DC_N, _DC_A + 5, 4); // -INF
        else
            return _debugRenderChars(pixel, origin, _DC_I, _DC_N, _DC_A + 5, _DC_SPACE, 3); // INF
    }

    int cellW = (_CHAR_W + _CHAR_GAP_X) * DEBUG_SCALE;
    ivec2 p = pixel - origin;
    if (p.y < 0 || p.y >= _CHAR_H * DEBUG_SCALE) return 0.0;

    int totalChars = 1 + intDigits + (fracDigits > 0 ? 1 + fracDigits : 0);
    if (p.x < 0 || p.x >= totalChars * cellW) return 0.0;

    int charIdx = p.x / cellW;
    int cx = (p.x % cellW) / DEBUG_SCALE;
    int cy = p.y / DEBUG_SCALE;
    if (cx >= _CHAR_W) return 0.0;

    bool negative = value < 0.0;
    float absVal = min(abs(value), pow(10.0, float(intDigits)) - 1.0);
    int intPart = int(absVal);
    float fracPart = fract(absVal);

    int charCode = _DC_SPACE;

    if (charIdx == 0) {
        charCode = negative ? _DC_MINUS : _DC_SPACE;
    } else if (charIdx <= intDigits) {
        int power = intDigits - charIdx;
        int divisor = int(pow(10.0, float(power)));
        if (power > 0 && intPart < divisor)
            charCode = _DC_SPACE; // suppress leading zeros
        else
            charCode = (intPart / divisor) % 10;
    } else if (fracDigits > 0 && charIdx == intDigits + 1) {
        charCode = _DC_DOT;
    } else if (fracDigits > 0) {
        int fracIdx = charIdx - intDigits - 2;
        charCode = int(mod(floor(fracPart * pow(10.0, float(fracIdx + 1))), 10.0));
    }

    return _debugCharPixel(charCode, ivec2(cx, cy));
}

// ============================================================================
// Public API
// ============================================================================

// --- Float ---

float debugFloat(ivec2 pixel, int line, float value, int decimals) {
    return _debugRenderFloat(pixel, _debugLineOrigin(line), value, DEBUG_INT_DIGITS, decimals);
}

float debugFloat(ivec2 pixel, int line, float value) {
    return debugFloat(pixel, line, value, DEBUG_FRAC_DIGITS);
}

// --- Int ---

float debugInt(ivec2 pixel, int line, int value) {
    return _debugRenderFloat(pixel, _debugLineOrigin(line), float(value), DEBUG_INT_DIGITS, 0);
}

// --- Uint (hex: 0xHHHHHHHH) ---

float debugUint(ivec2 pixel, int line, uint value) {
    int cellW = (_CHAR_W + _CHAR_GAP_X) * DEBUG_SCALE;
    ivec2 origin = _debugLineOrigin(line);
    ivec2 p = pixel - origin;

    if (p.y < 0 || p.y >= _CHAR_H * DEBUG_SCALE) return 0.0;
    if (p.x < 0 || p.x >= 10 * cellW) return 0.0; // "0xHHHHHHHH" = 10 chars

    int charIdx = p.x / cellW;
    int cx = (p.x % cellW) / DEBUG_SCALE;
    int cy = p.y / DEBUG_SCALE;
    if (cx >= _CHAR_W) return 0.0;

    int charCode;
    if (charIdx == 0) {
        charCode = 0; // '0'
    } else if (charIdx == 1) {
        charCode = _DC_X;
    } else {
        int nibbleIdx = 7 - (charIdx - 2);
        int nibble = int((value >> (nibbleIdx * 4)) & 0xFu);
        charCode = nibble < 10 ? nibble : (nibble - 10 + _DC_A);
    }

    return _debugCharPixel(charCode, ivec2(cx, cy));
}

// --- Vec types ---

float debugVec2(ivec2 pixel, int line, vec2 value) {
    ivec2 origin = _debugLineOrigin(line);
    int cellW = (_CHAR_W + _CHAR_GAP_X) * DEBUG_SCALE;
    int stride = (_debugFloatChars(DEBUG_FRAC_DIGITS) + 1) * cellW;

    float r = 0.0;
    r += _debugRenderFloat(pixel, origin,                    value.x, DEBUG_INT_DIGITS, DEBUG_FRAC_DIGITS);
    r += _debugRenderFloat(pixel, origin + ivec2(stride, 0), value.y, DEBUG_INT_DIGITS, DEBUG_FRAC_DIGITS);
    return min(r, 1.0);
}

float debugVec3(ivec2 pixel, int line, vec3 value) {
    ivec2 origin = _debugLineOrigin(line);
    int cellW = (_CHAR_W + _CHAR_GAP_X) * DEBUG_SCALE;
    int stride = (_debugFloatChars(DEBUG_FRAC_DIGITS) + 1) * cellW;

    float r = 0.0;
    r += _debugRenderFloat(pixel, origin,                        value.x, DEBUG_INT_DIGITS, DEBUG_FRAC_DIGITS);
    r += _debugRenderFloat(pixel, origin + ivec2(stride,     0), value.y, DEBUG_INT_DIGITS, DEBUG_FRAC_DIGITS);
    r += _debugRenderFloat(pixel, origin + ivec2(stride * 2, 0), value.z, DEBUG_INT_DIGITS, DEBUG_FRAC_DIGITS);
    return min(r, 1.0);
}

float debugVec4(ivec2 pixel, int line, vec4 value) {
    ivec2 origin = _debugLineOrigin(line);
    int cellW = (_CHAR_W + _CHAR_GAP_X) * DEBUG_SCALE;
    int stride = (_debugFloatChars(DEBUG_FRAC_DIGITS) + 1) * cellW;

    float r = 0.0;
    r += _debugRenderFloat(pixel, origin,                        value.x, DEBUG_INT_DIGITS, DEBUG_FRAC_DIGITS);
    r += _debugRenderFloat(pixel, origin + ivec2(stride,     0), value.y, DEBUG_INT_DIGITS, DEBUG_FRAC_DIGITS);
    r += _debugRenderFloat(pixel, origin + ivec2(stride * 2, 0), value.z, DEBUG_INT_DIGITS, DEBUG_FRAC_DIGITS);
    r += _debugRenderFloat(pixel, origin + ivec2(stride * 3, 0), value.w, DEBUG_INT_DIGITS, DEBUG_FRAC_DIGITS);
    return min(r, 1.0);
}

// --- Background overlay ---

float debugBg(ivec2 pixel, int numLines, int maxCharsPerLine) {
    int cellW = (_CHAR_W + _CHAR_GAP_X) * DEBUG_SCALE;
    int cellH = (_CHAR_H + _CHAR_GAP_Y) * DEBUG_SCALE;
    int pad = 4 * DEBUG_SCALE;

    ivec2 topLeft = DEBUG_ORIGIN - ivec2(pad);
    ivec2 size = ivec2(maxCharsPerLine * cellW + 2 * pad, numLines * cellH + 2 * pad);

    ivec2 p = pixel - topLeft;
    return (p.x >= 0 && p.x < size.x && p.y >= 0 && p.y < size.y) ? 1.0 : 0.0;
}

float debugBg(ivec2 pixel, int numLines) {
    return debugBg(pixel, numLines, _debugFloatChars(DEBUG_FRAC_DIGITS));
}

#endif // DEBUG_PRINT_GLSL
