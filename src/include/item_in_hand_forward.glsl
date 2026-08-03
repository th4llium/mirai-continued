#include "./lib/common.glsl"
#include "./lib/actor_util.glsl"
#include "./lib/taau_util.glsl"
#include "./lib/atmosphere.glsl"

///////////////////////////////////////////////////////////
// VERTEX SHADER
///////////////////////////////////////////////////////////
#if BGFX_SHADER_TYPE_VERTEX
#ifdef MATERIAL_ITEM_IN_HAND_FORWARD_PBR_GLINT
uniform vec4 UVAnimation;
uniform vec4 UVScale;
#endif

uniform mat4 PrevWorld;
uniform vec4 SunDir;
uniform vec4 MoonDir;
uniform vec4 DimensionID;

void main() {
#if INSTANCING__ON
    vec3 worldPos = mul(mtxFromCols(i_data1, i_data2, i_data3, vec4(0.0, 0.0, 0.0, 1.0)), vec4(a_position, 1.0)).xyz;
#else
    vec3 worldPos = mul(u_model[0], vec4(a_position, 1.0)).xyz;
#endif
    vec4 clipPos = jitterVertexPosition(worldPos);

#ifdef MATERIAL_ITEM_IN_HAND_FORWARD_PBR_TEXTURED
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
    v_clipPos = clipPos;

#ifdef MATERIAL_ITEM_IN_HAND_FORWARD_PBR_GLINT
    vec2 unpackedUV = unpackTerrainUV(a_texcoord0);
    v_glintUV.xy = calculateLayerUV(unpackedUV, UVAnimation.x, UVAnimation.z, UVScale.xy);
    v_glintUV.zw = calculateLayerUV(unpackedUV, UVAnimation.y, UVAnimation.w, UVScale.xy);
#endif

    //add smooth transition between night and sunrise, sunset and night
    float sunFade = smoothstep(0.0, 0.1, SunDir.y);
    float moonFade = smoothstep(0.0, 0.1, MoonDir.y);

    v_absorbColor = GetSunTransmittance(SunDir.xyz) * sunFade * SUN_MAX_ILLUMINANCE;
    v_absorbColor += GetMoonTransmittance(MoonDir.xyz) * moonFade * MOON_MAX_ILLUMINANCE;

    AtmosphereParams sunAtmParams;
    sunAtmParams.rayStart = vec3(0.0, 10.0, 0.0);
    sunAtmParams.rayDir = vec3(0.0, 1.0, 0.0);
    sunAtmParams.lightDir = SunDir.xyz;
    sunAtmParams.rayLength = 1e10;
    sunAtmParams.aerial = 1.0;
    sunAtmParams.occlusion = 1.0;
    sunAtmParams.mieMod = 1.0;
    v_scatterColor = GetAtmosphere(sunAtmParams) * SUN_MAX_ILLUMINANCE;

    AtmosphereParams moonAtmParams;
    moonAtmParams.rayStart = vec3(0.0, 10.0, 0.0);
    moonAtmParams.rayDir = vec3(0.0, 1.0, 0.0);
    moonAtmParams.lightDir = MoonDir.xyz;
    moonAtmParams.rayLength = 1e10;
    moonAtmParams.aerial = 1.0;
    moonAtmParams.occlusion = 1.0;
    moonAtmParams.mieMod = 1.0;
    v_scatterColor += GetAtmosphere(moonAtmParams) * MOON_MAX_ILLUMINANCE;

    if (int(DimensionID.r) != 0) {
        v_absorbColor = vec3_splat(0.0);
        v_scatterColor = vec3_splat(1.0);
    }

    gl_Position = clipPos;
}
#endif //BGFX_SHADER_TYPE_VERTEX





///////////////////////////////////////////////////////////
// FRAGMENT/PIXEL SHADER
///////////////////////////////////////////////////////////
#if BGFX_SHADER_TYPE_FRAGMENT
#if !DEPTH_ONLY_PASS && !DEPTH_ONLY_OPAQUE_PASS
uniform highp vec4 ChangeColor;
uniform highp vec4 ColorBased;
uniform highp vec4 GlintColor;
uniform highp vec4 OverlayColor;
uniform highp vec4 MatColor;
#if MULTI_COLOR_TINT__ON
uniform highp vec4 MultiplicativeTintColor;
#endif
uniform highp vec4 DirectionalLightSourceWorldSpaceDirection;
uniform highp vec4 BlockLightColor;
uniform highp vec4 TileLightIntensity;
uniform highp vec4 SunDir;
uniform highp vec4 MoonDir;
uniform highp vec4 CameraLightIntensity;
uniform highp vec4 CameraIsUnderwater;
uniform highp vec4 CausticsParameters;
uniform highp vec4 DimensionID;
uniform highp vec4 Time;
uniform highp vec4 WorldOrigin;
uniform highp vec4 FogAndDistanceControl;
uniform highp vec4 RenderChunkFogAlpha;
uniform highp vec4 FogColor;

#ifdef MATERIAL_ITEM_IN_HAND_FORWARD_PBR_TEXTURED
SAMPLER2D_HIGHP_AUTOREG(s_MatTexture);
#endif
#ifdef MATERIAL_ITEM_IN_HAND_FORWARD_PBR_GLINT
SAMPLER2D_HIGHP_AUTOREG(s_GlintTexture);
#endif

SAMPLER2D_HIGHP_AUTOREG(s_PreviousFrameAverageLuminance);

#include "./lib/materials.glsl"
#include "./lib/shadow.glsl"
#include "./lib/bsdf.glsl"
#include "./lib/ibl.glsl"
#include "./lib/volumetrics.glsl"
#endif

void main() {
#if DEPTH_ONLY_PASS
    gl_FragData[0] = vec4_splat(0.0);
    gl_FragData[1] = vec4_splat(0.0);
#elif DEPTH_ONLY_OPAQUE_PASS
    gl_FragData[0] = vec4_splat(1.0);
    gl_FragData[1] = vec4_splat(0.0);
#else

    //PBR materials setup
#ifdef MATERIAL_ITEM_IN_HAND_FORWARD_PBR_TEXTURED
    vec4 mers = vec4(0.0, 0.0, 1.0, 0.0);
    vec3 normal = gl_FrontFacing ? -v_normal : v_normal;
    normal = normalize(normal);
    getTexturePBRMaterials(s_MatTexture, v_pbrTextureId, v_texcoord0, v_tangent, v_bitangent, normal, mers);

    vec4 albedo = texture2D(s_MatTexture, v_texcoord0) * MatColor;
    albedo.rgb *= mix(vec3_splat(1.0), v_color0.rgb, ColorBased.x);
#if MULTI_COLOR_TINT__OFF
    albedo.rgb = mix(albedo.rgb, ChangeColor.rgb * albedo.rgb, albedo.a);
#endif

#if FORWARD_PBR_ALPHA_TEST_PASS
    if (albedo.a < 0.5) discard;
#endif

#else
    vec4 mers = v_mers;
    vec3 normal = normalize(v_normal);
    vec4 albedo = mix(vec4_splat(1.0), vec4(v_color0.rgb, 1.0), ColorBased.x);
#if MULTI_COLOR_TINT__OFF
    albedo.rgb *= ChangeColor.rgb;
#endif
#endif //MATERIAL_ITEM_IN_HAND_FORWARD_PBR_TEXTURED

#if MULTI_COLOR_TINT__ON
    albedo.rgb = applyMultiColorChange(albedo.rgb, ChangeColor.rgb, MultiplicativeTintColor.rgb);
#endif
    albedo.rgb = mix(albedo.rgb, OverlayColor.rgb, OverlayColor.a);
#ifdef MATERIAL_ITEM_IN_HAND_FORWARD_PBR_GLINT
    albedo.rgb = applyGlint(albedo.rgb, v_glintUV, s_GlintTexture, GlintColor);
#endif

    albedo.rgb = toLinear(albedo.rgb);
    vec3 f0 = mix(vec3_splat(0.02), albedo.rgb, mers.r);

    //ambient lighting
    vec3 blockAmbient = BlockLightColor.rgb;
    if ((blockAmbient.r + blockAmbient.g + blockAmbient.b) <= 0.0 && TileLightIntensity.r > 0.0) {
        float blm = TileLightIntensity.r * TileLightIntensity.r;
        blockAmbient = saturate(vec3(blm, blm * ((blm * 0.6 + 0.4) * 0.6 + 0.4), blm * ((blm * blm * 0.6) + 0.4)));
    }

    float skylmContrib = mix(pow(TileLightIntensity.g, 3.0), pow(TileLightIntensity.g, 5.0), CameraLightIntensity.g);
    if (int(DimensionID.r) == 1) skylmContrib = 0.05;
    if (int(DimensionID.r) == 2) skylmContrib = 0.02;
    vec3 skyAmbient = (v_scatterColor + v_absorbColor / SUN_MAX_ILLUMINANCE) * skylmContrib * SKY_AMBIENT_INTENSITY;

    vec3 ambientLight = max(blockAmbient + skyAmbient, vec3_splat(MIN_AMBIENT_LIGHT));
    vec3 outColor = ambientLight * albedo.rgb * (1.0 - mers.r);

    //directional lighting
    vec3 shadowMap = calcShadowMap(v_worldPos, normal).rgr;

#ifdef VOLUMETRIC_CLOUDS_ENABLED
    vec3 position = v_worldPos - WorldOrigin.xyz;
    CloudSetup cloudSetup = calcCloudSetup(DirectionalLightSourceWorldSpaceDirection.y, position.y);
    float cloudShadow = calcCloudShadow(position, DirectionalLightSourceWorldSpaceDirection.xyz, 2.0, cloudSetup);
    shadowMap.rg = min(shadowMap.rg, vec2_splat(cloudShadow * CLOUD_SHADOW_CONTRIBUTION + (1.0 - CLOUD_SHADOW_CONTRIBUTION)));
    shadowMap.b = min(shadowMap.b, cloudShadow); //used for specular
#endif

    vec3 worldDir = normalize(v_worldPos);
    vec3 bsdf = BSDF(normal, DirectionalLightSourceWorldSpaceDirection.xyz, -worldDir, f0, albedo.rgb, shadowMap, mers.r, mers.b, mers.a);
    outColor += bsdf * v_absorbColor;

    //always lit
    outColor += albedo.rgb * mers.g * EMISSIVE_MATERIAL_INTENSITY;

    float worldDist = length(v_worldPos);

    bool isWaterBody = CausticsParameters.a > 0.0;

    if (int(DimensionID.r) == 0) {
        //reflections
        outColor += indirectSpecular(f0, worldDir, normal, blockAmbient, mers.b, mers.r, TileLightIntensity.g, !isWaterBody);

#ifdef VOLUMETRIC_CLOUDS_ENABLED
        float dither = texelFetch(s_CausticsTexture, ivec3(ivec2(gl_FragCoord.xy) % 256, 1), 0).r;
        applyCumulusClouds(outColor, v_absorbColor, worldDir, worldDist, dither, true);
#endif

        //underwater extinction and scattering
        if (isWaterBody) {
            outColor *= exp(-WATER_EXTINCTION_COEFFICIENTS * worldDist);
            vec3 wscattering = exp(-WATER_EXTINCTION_COEFFICIENTS * 10.0) * luminance(v_absorbColor) * CameraLightIntensity.y;
            outColor = mix(outColor, wscattering, 0.01);
        }

        vec3 projPos = v_clipPos.xyz / v_clipPos.w;
        applyVolumetricFog(outColor, projPos);
    } else {
        float wDistNorm = worldDist / FogAndDistanceControl.z;
        float borderFog = saturate((wDistNorm + RenderChunkFogAlpha.x - FogAndDistanceControl.x) * FogAndDistanceControl.y);
        vec3 linFogColor = toLinear(FogColor.rgb);
        outColor = mix(outColor, linFogColor, borderFog);
    }

    outColor = preExposeLighting(outColor, texture2D(s_PreviousFrameAverageLuminance, vec2_splat(0.5)).r);

    gl_FragData[0] = vec4(outColor, albedo.a);
    gl_FragData[1] = vec4(0.0, 0.0, calculateMotionVector(v_worldPos, v_prevWorldPos));
#endif
}

#endif //BGFX_SHADER_TYPE_FRAGMENT
