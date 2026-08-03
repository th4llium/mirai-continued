#include "./lib/common.glsl"
#include "./lib/taau_util.glsl"


///////////////////////////////////////////////////////////
// VERTEX SHADER
///////////////////////////////////////////////////////////
#if BGFX_SHADER_TYPE_VERTEX
uniform vec4 ViewPositionAndTime;
void main() {
#if INSTANCING__ON
    vec3 worldPos = mul(mtxFromCols(i_data1, i_data2, i_data3, vec4(0.0, 0.0, 0.0, 1.0)), vec4(a_position, 1.0)).xyz;
#else
    vec3 worldPos = mul(u_model[0], vec4(a_position, 1.0)).xyz;
#endif

#if RENDER_AS_BILLBOARDS__ON
    vec4 color = vec4_splat(1.0);
    worldPos += vec3_splat(0.5);
    vec3 forward = normalize(worldPos - ViewPositionAndTime.xyz);
    vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), forward));
    vec3 up = cross(forward, right);
    vec3 offsets = a_color0.xyz;
    worldPos -= up * (offsets.z - 0.5) + right * (offsets.x - 0.5);
#else
    vec4 color = a_color0;
#endif

    v_texcoord0 = unpackTerrainUV(a_texcoord0);

#if !DEPTH_ONLY_PASS && !DEPTH_ONLY_OPAQUE_PASS
    uvec2 data16 = uvec2(a_texcoord1 * 65535.0);
    uvec2 highByte = (data16 >> 8) & 0xFFu;
    uvec2 lowByte = data16 & 0xFFu;
    uvec2 mHighByte = highByte & 0xFFu;
    v_ditheringAndMaskTinting = vec2(notEqual((highByte & uvec2(1u, 1u)), uvec2(0u, 0u)));
    float lintensity = a_normal.w * 0.5 + 0.5;
    v_lightColor = vec3(mHighByte.x, lowByte.x, mHighByte.y) / 255.0 * lintensity * 6.0;
    v_lightmapUV = vec2(uvec2(data16.y >> 4, data16.y) & 15u) / 15.0;
    v_pbrTextureId = a_texcoord4 & 0xFFFF;
    v_normal = mul(u_model[0], vec4(a_normal.xyz, 0.0)).xyz;
    v_tangent = mul(u_model[0], vec4(a_tangent.xyz, 0.0)).xyz;
    v_bitangent = mul(u_model[0], vec4(cross(a_normal.xyz, a_tangent.xyz) * a_tangent.w, 0.0)).xyz;
    v_worldPos = worldPos;
    v_color0 = color;
#endif

#if GEOMETRY_PREPASS_PASS || GEOMETRY_PREPASS_ALPHA_TEST_PASS
    gl_Position = jitterVertexPosition(worldPos);
#else
    gl_Position = mul(u_viewProj, vec4(worldPos, 1.0));
#endif
}
#endif //BGFX_SHADER_TYPE_VERTEX




///////////////////////////////////////////////////////////
// FRAGMENT/PIXEL SHADER
///////////////////////////////////////////////////////////
#if BGFX_SHADER_TYPE_FRAGMENT
SAMPLER2D_HIGHP_AUTOREG(s_MatTexture);

#if DEPTH_ONLY_PASS
void main() {
    if (texture2D(s_MatTexture, v_texcoord0).a < 0.5) discard;
    gl_FragColor = vec4_splat(1.0);
}
#elif DEPTH_ONLY_OPAQUE_PASS
void main() {
    gl_FragColor = vec4_splat(1.0);
}
#else

SAMPLER2D_HIGHP_AUTOREG(s_SeasonsTexture);

#include "./lib/common.glsl"
#include "./lib/materials.glsl"

void main() {
    vec3 normal = gl_FrontFacing ? -v_normal : v_normal;
    normal = normalize(normal);
    vec4 mers = vec4(0.0, 0.0, 1.0, 0.0);
    getTexturePBRMaterials(s_MatTexture, v_pbrTextureId, v_texcoord0, v_tangent, v_bitangent, normal, mers);

    vec4 albedo = texture2D(s_MatTexture, v_texcoord0);
#if GEOMETRY_PREPASS_ALPHA_TEST_PASS
    if (albedo.a < 0.5) discard;
#endif
#if SEASONS__ON
    albedo.rgb *= mix(vec3_splat(1.0), texture2D(s_SeasonsTexture, v_color0.rg).rgb * 2.0, v_color0.b);
    float vanillaAO = v_color0.a; //in case of snow leaves, baked ao is stored in alpha component
#else
    //normalize vertex color to get rid ambient occlusion
    vec3 nColor = normalize(v_color0.rgb);
    float nColorAvg = colorAvg(nColor);

    //get ambient occlusion by using color average
    float vanillaAO = colorAvg(v_color0.rgb);

    //blocks that need vertex color tint
    if (any(notEqual(nColor.ggb, nColor.brr))) {
        albedo.rgb *= nColor;
        vanillaAO /= nColorAvg;
    }

    // not tested yet
    if (v_ditheringAndMaskTinting.y > 0.0) vanillaAO = v_color0.a;
    albedo.rgb *= nColorAvg; //normalize albedo brightness
#endif

    vec3 lightColor = v_lightColor;
    if ((lightColor.r + lightColor.g + lightColor.b) <= 0.0 && v_lightmapUV.x > 0.0) {
        float blm = v_lightmapUV.x * v_lightmapUV.x;
        lightColor = saturate(vec3(blm, blm * ((blm * 0.6 + 0.4) * 0.6 + 0.4), blm * ((blm * blm * 0.6) + 0.4)));
    }
    lightColor /= 6.0;
    float maxVal = ceil(saturate(max(max(lightColor.r, lightColor.g), lightColor.b)) * 255.0) / 255.0;
    lightColor /= maxVal;

    gl_FragData[0] = uvec4(pack2x8(mers.bg), pack2x8(lightColor.rg), pack2x8(vec2(lightColor.b, maxVal)), pack2x8(vec2(vanillaAO, v_lightmapUV.y)));
    gl_FragData[1] = vec4(albedo.rgb, packMetalnessSubsurface(mers.r, mers.a));
    gl_FragData[2].xy = ndirToOctSnorm(normal);
    gl_FragData[2].zw = calculateMotionVector(v_worldPos, v_worldPos - u_prevWorldPosOffset.xyz);
}
#endif //!DEPTH_ONLY_OPAQUE_PASS
#endif //BGFX_SHADER_TYPE_FRAGMENT
