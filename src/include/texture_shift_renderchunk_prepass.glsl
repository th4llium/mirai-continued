#include "./lib/taau_util.glsl"
#include "./lib/common.glsl"

//currently dont know what things are rendered by this material


///////////////////////////////////////////////////////////
// VERTEX SHADER
///////////////////////////////////////////////////////////
#if BGFX_SHADER_TYPE_VERTEX
void main() {
#if INSTANCING__ON
    vec3 worldPos = mul(mtxFromCols(i_data1, i_data2, i_data3, vec4(0.0, 0.0, 0.0, 1.0)), vec4(a_position, 1.0)).xyz;
#else
    vec3 worldPos = mul(u_model[0], vec4(a_position, 1.0)).xyz;
#endif

    v_texcoord0 = unpackTerrainUV(a_texcoord0);
    v_textureShift = a_texcoord2;

#if !DEPTH_ONLY_PASS
    uvec2 data16 = uvec2(a_texcoord1 * 65535.0);
    uvec2 highByte = (data16 >> 8) & 0xFFu;
    uvec2 lowByte = data16 & 0xFFu;
    uvec2 mHighByte = highByte & 0xFFu;
    float lintensity = a_normal.w * 0.5 + 0.5;
    v_lightColor = vec3(mHighByte.x, lowByte.x, mHighByte.y) / 255.0 * lintensity * 6.0;
    v_lightmapUV = vec2(uvec2(data16.y >> 4, data16.y) & 15u) / 15.0;
    v_normal = mul(u_model[0], vec4(a_normal.xyz, 0.0)).xyz;
    v_tangent = mul(u_model[0], vec4(a_tangent.xyz, 0.0)).xyz;
    v_bitangent = mul(u_model[0], vec4(cross(a_normal.xyz, a_tangent.xyz) * a_tangent.w, 0.0)).xyz;
    v_worldPos = worldPos;
    v_color0 = a_color0;
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
struct TextureShiftBuffer {
    highp float preUV0;
    highp float preUV1;
    highp float postUV0;
    highp float postUV1;
    int packedPBRId;
    highp float globalAlpha;
    highp float localShiftLength;
};
BUFFER_RO_AUTOREG(s_TextureShiftBufferData, TextureShiftBuffer);

SAMPLER2D_HIGHP_AUTOREG(s_MatTexture);

#if DEPTH_ONLY_PASS
void main() {
    int shiftBufferIndex = int(v_textureShift.y * 65535.0) & 0xFFFF;
    TextureShiftBuffer textureShiftBuffer = s_TextureShiftBufferData[shiftBufferIndex];
    vec4 preFrameSample = texture2D(s_MatTexture, vec2(v_texcoord0.x + textureShiftBuffer.preUV0, v_texcoord0.y + textureShiftBuffer.preUV1));
    vec4 postFrameSample = texture2D(s_MatTexture, vec2(v_texcoord0.x + textureShiftBuffer.postUV0, v_texcoord0.y + textureShiftBuffer.postUV1));
    float blendFactor = saturate((textureShiftBuffer.globalAlpha - ((1.0 - textureShiftBuffer.localShiftLength) * v_textureShift.x)) / textureShiftBuffer.localShiftLength);
    vec4 albedo = mix(preFrameSample, postFrameSample, blendFactor);
    if (albedo.a < 0.5) discard;
    gl_FragColor = vec4_splat(0.0);
}

#else

#include "./lib/materials.glsl"

void main() {
    int shiftBufferIndex = int(v_textureShift.y * 65535.0) & 0xFFFF;
    TextureShiftBuffer textureShiftBuffer = s_TextureShiftBufferData[shiftBufferIndex];

    vec4 preFrameSample = texture2D(s_MatTexture, vec2(v_texcoord0.x + textureShiftBuffer.preUV0, v_texcoord0.y + textureShiftBuffer.preUV1));
    vec4 postFrameSample = texture2D(s_MatTexture, vec2(v_texcoord0.x + textureShiftBuffer.postUV0, v_texcoord0.y + textureShiftBuffer.postUV1));
    float blendFactor = saturate((textureShiftBuffer.globalAlpha - ((1.0 - textureShiftBuffer.localShiftLength) * v_textureShift.x)) / textureShiftBuffer.localShiftLength);
    vec4 albedo = mix(preFrameSample, postFrameSample, blendFactor);
#if GEOMETRY_PREPASS_ALPHA_TEST_PASS
    if (albedo.a < 0.5) discard;
#endif
    albedo.rgb *= v_color0.rgb * 0.5;

    vec2 adjustedUV = vec2(v_texcoord0.x + textureShiftBuffer.postUV0, v_texcoord0.y + textureShiftBuffer.postUV1);
    int pbrTextureId = textureShiftBuffer.packedPBRId & 0xFFFF;

    if (blendFactor < 0.5) {
        adjustedUV = vec2(v_texcoord0.x + textureShiftBuffer.preUV0, v_texcoord0.y + textureShiftBuffer.preUV1);
        pbrTextureId = (textureShiftBuffer.packedPBRId >> 16) & 0xFFFF;
    }

    vec3 normal = gl_FrontFacing ? -v_normal : v_normal;
    normal = normalize(normal);
    vec4 mers = vec4(0.0, 0.0, 1.0, 0.0);
    getTexturePBRMaterials(s_MatTexture, pbrTextureId, adjustedUV, v_tangent, v_bitangent, normal, mers);

    vec3 lightColor = v_lightColor;
    if ((lightColor.r + lightColor.g + lightColor.b) <= 0.0 && v_lightmapUV.x > 0.0) {
        float blm = v_lightmapUV.x * v_lightmapUV.x;
        lightColor = saturate(vec3(blm, blm * ((blm * 0.6 + 0.4) * 0.6 + 0.4), blm * ((blm * blm * 0.6) + 0.4)));
    }
    lightColor /= 6.0;
    float maxVal = ceil(saturate(max(max(lightColor.r, lightColor.g), lightColor.b)) * 255.0) / 255.0;
    lightColor /= maxVal;

    gl_FragData[0] = uvec4(pack2x8(mers.bg), pack2x8(lightColor.rg), pack2x8(vec2(lightColor.b, maxVal)), pack2x8(vec2(1.0, v_lightmapUV.y)));
    gl_FragData[1] = vec4(albedo.rgb, packMetalnessSubsurface(mers.r, mers.a));
    gl_FragData[2].xy = ndirToOctSnorm(normal);
    gl_FragData[2].zw = calculateMotionVector(v_worldPos, v_worldPos - u_prevWorldPosOffset.xyz);
}
#endif //DEPTH_ONLY_PASS
#endif //BGFX_SHADER_TYPE_FRAGMENT
