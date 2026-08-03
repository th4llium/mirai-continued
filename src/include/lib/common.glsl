#ifndef COMMON_INCLUDE
#define COMMON_INCLUDE

#define EPSILON 0.0001

#define PI      3.14159265358979
#define HALF_PI 1.57079632679489

#define LUMA_REC709 vec3(0.2126, 0.7152, 0.0722)
#define MIDDLE_GRAY 0.18

#define SKY_AMBIENT_INTENSITY       4.0
#define EMISSIVE_MATERIAL_INTENSITY 50.0
#define MIN_AMBIENT_LIGHT           0.001

#define SUN_MAX_ILLUMINANCE  100.0
#define MOON_MAX_ILLUMINANCE 0.1

#define WATER_EXTINCTION_COEFFICIENTS vec3(0.5, 0.35, 0.3)

float luminance(vec3 color) {
    return dot(color, LUMA_REC709);
}

float colorAvg(vec3 color) {
    return (color.r + color.g + color.b) / 3.0;
}

float linearstep(float edge0, float edge1, float x) {
    return clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
}

vec3 saturation(vec3 color, float val) {
	float lum = luminance(color);
    return mix(vec3_splat(lum), color, val);
}

vec3 preExposeLighting(vec3 color, float luminance) {
    return color * (MIDDLE_GRAY / luminance + EPSILON);
}

vec3 unExposeLighting(vec3 color, float luminance) {
    return color / (MIDDLE_GRAY / luminance + EPSILON);
}

uint pack2x8(vec2 values) {
    uvec2 bytes = uvec2(saturate(values) * 255.0) & 0xFFu;
    return (bytes.x << 8) | bytes.y;
}

float sampleDepth(highp sampler2D depthtex, vec2 uv) {
#if BGFX_SHADER_LANGUAGE_GLSL
    return texture2DLod(depthtex, uv, 0.0).r * 2.0 - 1.0;
#else
    return texture2DLod(depthtex, uv, 0.0).r;
#endif
}

float PhaseHG(float costh, float g) {
    float num = (1.0 - g * g) * (1.0 + costh * costh);
    float denom = (2.0 + g * g) * pow((1.0 + g * g - 2.0 * g * costh), 1.5);
    return 3.0 / (8.0 * PI) * num / denom;
}

float PhaseR(float costh) {
    return 3.0 / (16.0 * PI) * (1.0 + costh * costh);
}

vec3 toLinear(vec3 sRGB) {
    bvec3 cutoff = lessThan(sRGB, vec3_splat(0.04045));
    vec3 higher = pow((sRGB + vec3_splat(0.055)) / vec3_splat(1.055), vec3_splat(2.4));
    vec3 lower = sRGB / vec3_splat(12.92);

    return mix(higher, lower, cutoff);
}

vec3 fromLinear(vec3 linearRGB) {
    bvec3 cutoff = lessThan(linearRGB, vec3_splat(0.0031308));
    vec3 higher = vec3_splat(1.055) * pow(linearRGB, vec3_splat(1.0 / 2.4)) - vec3_splat(0.055);
    vec3 lower = linearRGB * vec3_splat(12.92);

    return mix(higher, lower, cutoff);
}

float pow2(float x) { return x * x; }
float pow3(float x) { return x * x * x; }
float pow4(float x) { return x * x * x * x; }
float pow5(float x) { return x * x * x * x * x; }
float pow6(float x) { return x * x * x * x * x * x; }
float pow7(float x) { return x * x * x * x * x * x * x; }
float pow8(float x) { return x * x * x * x * x * x * x * x; }

vec2 unpackTerrainUV(vec2 rawTexcoord) {
    CONST(float) kUVScale = 1.0 / 65535.0;
    CONST(float) kBiasScale = 1.0 / 32768.0;
    uvec2 packedUV = uvec2(round(rawTexcoord * 65535.0));
    vec2 uv = vec2(
        float((packedUV.x & 0x7FFFu) << 1u),
        float((packedUV.y & 0x7FFFu) << 1u)
    ) * kUVScale;
    uv.x += kBiasScale * ((2.0 * float((packedUV.x & 0x8000u) >> 15u)) - 1.0);
    uv.y += kBiasScale * ((2.0 * float((packedUV.y & 0x8000u) >> 15u)) - 1.0);
    return uv;
}

#endif
