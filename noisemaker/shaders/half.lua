-- IEEE-754 binary32 <-> binary16, round-to-nearest-even, for GLSL 3.30 / ES 3.00.
return [[
uint nmFloatToHalf(float value) {
  uint bits = floatBitsToUint(value);
  uint sign = (bits >> 16u) & 0x8000u;
  uint exponent = (bits >> 23u) & 0xffu;
  uint mantissa = bits & 0x7fffffu;
  if (exponent == 255u) {
    return sign | (mantissa == 0u ? 0x7c00u : 0x7e00u);
  }
  int halfExponent = int(exponent) - 112;
  if (halfExponent >= 31) return sign | 0x7c00u;
  if (halfExponent <= 0) {
    if (halfExponent < -10) return sign;
    uint full = mantissa | 0x800000u;
    uint shift = uint(14 - halfExponent);
    uint halfMantissa = full >> shift;
    uint remainder = full & ((1u << shift) - 1u);
    uint halfway = 1u << (shift - 1u);
    if (remainder > halfway || (remainder == halfway && (halfMantissa & 1u) != 0u)) halfMantissa++;
    return sign | halfMantissa;
  }
  uint halfMantissa = mantissa >> 13u;
  uint remainder = mantissa & 0x1fffu;
  if (remainder > 0x1000u || (remainder == 0x1000u && (halfMantissa & 1u) != 0u)) halfMantissa++;
  if (halfMantissa == 0x400u) {
    halfMantissa = 0u;
    halfExponent++;
    if (halfExponent >= 31) return sign | 0x7c00u;
  }
  return sign | (uint(halfExponent) << 10u) | halfMantissa;
}
float nmHalfToFloat(uint halfBits) {
  uint sign = (halfBits & 0x8000u) << 16u;
  uint exponent = (halfBits >> 10u) & 31u;
  uint mantissa = halfBits & 0x3ffu;
  if (exponent == 0u) {
    if (mantissa == 0u) return uintBitsToFloat(sign);
    float value = float(mantissa) * 5.9604644775390625e-8;
    return sign == 0u ? value : -value;
  }
  if (exponent == 31u) return uintBitsToFloat(sign | 0x7f800000u | (mantissa << 13u));
  return uintBitsToFloat(sign | ((exponent + 112u) << 23u) | (mantissa << 13u));
}
uint nmPackHalf2x16(vec2 values) {
  return nmFloatToHalf(values.x) | (nmFloatToHalf(values.y) << 16u);
}
vec2 nmUnpackHalf2x16(uint packed) {
  return vec2(nmHalfToFloat(packed & 0xffffu), nmHalfToFloat(packed >> 16u));
}
]]
