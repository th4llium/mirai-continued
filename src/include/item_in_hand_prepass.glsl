#include "./lib/common.glsl"
#include "./lib/actor_util.glsl"
#include "./lib/taau_util.glsl"


///////////////////////////////////////////////////////////
// VERTEX SHADER
///////////////////////////////////////////////////////////
#if BGFX_SHADER_TYPE_VERTEX
#ifdef MATERIAL_ITEM_IN_HAND_PREPASS_GLINT
uniform vec4 UVAnimation;
uniform vec4 UVScale;
#endif
uniform mat4 PrevWorld;

void main() {
#if INSTANCING__ON
    vec3 worldPos = mul(mtxFromCols(i_data1, i_data2, i_data3, vec4(0.0, 0.0, 0.0, 1.0)), vec4(a_position, 1.0)).xyz;
#else
    vec3 worldPos = mul(u_model[0], vec4(a_position, 1.0)).xyz;
#endif

#if !DEPTH_ONLY_PASS && !DEPTH_ONLY_OPAQUE_PASS
#ifdef MATERIAL_ITEM_IN_HAND_PREPASS_TEXTURED
    v_texcoord0 = unpackTerrainUV(a_texcoord0);
    v_pbrTextureId = int(a_texcoord4);
    v_tangent = mul(u_model[0], vec4(a_tangent.xyz, 0.0)).xyz;
    v_bitangent = mul(u_model[0], vec4(cross(a_normal.xyz, a_tangent.xyz) * a_tangent.w, 0.0)).xyz;
#else
    v_mers = a_texcoord8;
#endif

    v_color0 = a_color0;
    v_worldPos = worldPos;
    v_normal = mul(u_model[0], vec4(a_normal.xyz, 0.0)).xyz;
    v_prevWorldPos = mul(PrevWorld, vec4(a_position, 1.0)).xyz;

#ifdef MATERIAL_ITEM_IN_HAND_PREPASS_GLINT
    vec2 unpackedUV = unpackTerrainUV(a_texcoord0);
    v_glintUV.xy = calculateLayerUV(unpackedUV, UVAnimation.x, UVAnimation.z, UVScale.xy);
    v_glintUV.zw = calculateLayerUV(unpackedUV, UVAnimation.y, UVAnimation.w, UVScale.xy);
#endif
#endif //!DEPTH_ONLY_PASS && !DEPTH_ONLY_OPAQUE_PASS

    gl_Position = jitterVertexPosition(worldPos);
}
#endif //BGFX_SHADER_TYPE_VERTEX




///////////////////////////////////////////////////////////
// FRAGMENT/PIXEL SHADER
///////////////////////////////////////////////////////////
#if BGFX_SHADER_TYPE_FRAGMENT
#if DEPTH_ONLY_PASS
void main() {
    gl_FragColor = vec4_splat(0.0);
}
#elif DEPTH_ONLY_OPAQUE_PASS
void main() {
    gl_FragColor = vec4_splat(1.0);
}
#else

uniform highp vec4 ChangeColor;
uniform highp vec4 ColorBased;
uniform highp vec4 GlintColor;
uniform highp vec4 OverlayColor;
uniform highp vec4 MatColor;
uniform highp vec4 MultiplicativeTintColor;
uniform highp vec4 BlockLightColor;
uniform highp vec4 TileLightIntensity;

#ifdef MATERIAL_ITEM_IN_HAND_PREPASS_TEXTURED
SAMPLER2D_HIGHP_AUTOREG(s_MatTexture);
#endif

#ifdef MATERIAL_ITEM_IN_HAND_PREPASS_GLINT
SAMPLER2D_HIGHP_AUTOREG(s_GlintTexture);
#endif

#include "./lib/materials.glsl"

void main() {
#ifdef MATERIAL_ITEM_IN_HAND_PREPASS_TEXTURED
    vec4 mers = vec4(0.0, 0.0, 1.0, 0.0);
    vec3 normal = gl_FrontFacing ? -v_normal : v_normal;
    normal = normalize(normal);
    getTexturePBRMaterials(s_MatTexture, v_pbrTextureId, v_texcoord0, v_tangent, v_bitangent, normal, mers);

    vec4 albedo = texture2D(s_MatTexture, v_texcoord0) * MatColor;
    albedo.rgb *= mix(vec3_splat(1.0), v_color0.rgb, ColorBased.x);
#if MULTI_COLOR_TINT__OFF
    albedo.rgb = mix(albedo.rgb, ChangeColor.rgb * albedo.rgb, albedo.a);
#endif

#if GEOMETRY_PREPASS_ALPHA_TEST_PASS
    if (albedo.a < 0.5) discard;
#endif

#else
    vec4 mers = v_mers;
    vec3 normal = normalize(v_normal);
    vec4 albedo = mix(vec4_splat(1.0), vec4(v_color0.rgb, 1.0), ColorBased.x);
#if MULTI_COLOR_TINT__OFF
    albedo.rgb *= ChangeColor.rgb;
#endif
#endif //MATERIAL_ITEM_IN_HAND_PREPASS_TEXTURED

#if MULTI_COLOR_TINT__ON
    albedo.rgb = applyMultiColorChange(albedo.rgb, ChangeColor.rgb, MultiplicativeTintColor.rgb);
#endif
    albedo.rgb = mix(albedo.rgb, OverlayColor.rgb, OverlayColor.a);
#ifdef MATERIAL_ITEM_IN_HAND_PREPASS_GLINT
    albedo.rgb = applyGlint(albedo.rgb, v_glintUV, s_GlintTexture, GlintColor);
#endif

    albedo.rgb *= 0.5; //decrease albedo brightness to match terrain

    vec3 lightColor = BlockLightColor.rgb;
    if ((lightColor.r + lightColor.g + lightColor.b) <= 0.0 && TileLightIntensity.x > 0.0) {
        float blm = TileLightIntensity.x * TileLightIntensity.x;
        lightColor = saturate(vec3(blm, blm * ((blm * 0.6 + 0.4) * 0.6 + 0.4), blm * ((blm * blm * 0.6) + 0.4)));
    }
    lightColor /= 6.0;
    float maxVal = ceil(saturate(max(max(lightColor.r, lightColor.g), lightColor.b)) * 255.0) / 255.0;
    lightColor /= maxVal;

    gl_FragData[0] = uvec4(pack2x8(mers.bg), pack2x8(lightColor.rg), pack2x8(vec2(lightColor.b, maxVal)), pack2x8(vec2(1.0, TileLightIntensity.y)));
    gl_FragData[1] = vec4(albedo.rgb, packMetalnessSubsurface(mers.r, mers.a));
    gl_FragData[2].xy = ndirToOctSnorm(normal);
    gl_FragData[2].zw = calculateMotionVector(v_worldPos, v_prevWorldPos - u_prevWorldPosOffset.xyz);
}
#endif //!DEPTH_ONLY_OPAQUE_PASS

#endif //BGFX_SHADER_TYPE_FRAGMENT
