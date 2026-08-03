#include "./lib/taau_util.glsl"
#include "./lib/common.glsl"
#include "./lib/atmosphere.glsl"


///////////////////////////////////////////////////////////
// VERTEX SHADER
///////////////////////////////////////////////////////////
#if BGFX_SHADER_TYPE_VERTEX
uniform vec4 SunDir;
uniform vec4 MoonDir;
uniform vec4 DimensionID;
uniform vec4 ViewPositionAndTime;

void main() {
#if INSTANCING__ON
    vec3 worldPos = mul(mtxFromCols(i_data1, i_data2, i_data3, vec4(0.0, 0.0, 0.0, 1.0)), vec4(a_position, 1.0)).xyz;
#else
    vec3 worldPos = mul(u_model[0], vec4(a_position, 1.0)).xyz;
#endif

    v_texcoord0 = unpackTerrainUV(a_texcoord0);
    uvec2 data16 = uvec2(a_texcoord1 * 65535.0);
    uvec2 highByte = (data16 >> 8) & 0xFFu;
    uvec2 lowByte = data16 & 0xFFu;
    uvec2 mHighByte = highByte & 0xFFu;
    float lintensity = a_normal.w * 0.5 + 0.5;
    v_lightColor = vec3(mHighByte.x, lowByte.x, mHighByte.y) / 255.0 * lintensity * 6.0;
    v_lightmapUV = vec2(uvec2(data16.y >> 4, data16.y) & 15u) / 15.0;

#if DEPTH_ONLY_PASS || DEPTH_ONLY_OPAQUE_PASS
#if RENDER_AS_BILLBOARDS__ON
    worldPos += vec3_splat(0.5);
    vec3 forward = normalize(worldPos - ViewPositionAndTime.xyz);
    vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), forward));
    vec3 up = cross(forward, right);
    vec3 offsets = a_color0.xyz;
    worldPos -= up * (offsets.z - 0.5) + right * (offsets.x - 0.5);
#endif

    gl_Position = mul(u_viewProj, vec4(worldPos, 1.0));
#else
    v_pbrTextureId = a_texcoord4 & 0xFFFF;
    v_normal = mul(u_model[0], vec4(a_normal.xyz, 0.0)).xyz;
    v_tangent = mul(u_model[0], vec4(a_tangent.xyz, 0.0)).xyz;
    v_bitangent = mul(u_model[0], vec4(cross(a_normal.xyz, a_tangent.xyz) * a_tangent.w, 0.0)).xyz;
    v_worldPos = worldPos;
    v_color0 = a_color0;
    v_clipPos = mul(u_viewProj, vec4(worldPos, 1.0));

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

    gl_Position = jitterVertexPosition(worldPos);
#endif //DEPTH_ONLY_PASS || DEPTH_ONLY_OPAQUE_PASS
}
#endif //BGFX_SHADER_TYPE_VERTEX





///////////////////////////////////////////////////////////
// FRAGMENT/PIXEL SHADER
///////////////////////////////////////////////////////////
#if BGFX_SHADER_TYPE_FRAGMENT
SAMPLER2D_HIGHP_AUTOREG(s_MatTexture);
SAMPLER2D_HIGHP_AUTOREG(s_LightMapTexture);

#if !DEPTH_ONLY_PASS && !DEPTH_ONLY_OPAQUE_PASS
uniform highp vec4 CausticsParameters;
uniform highp vec4 CameraLightIntensity;
uniform highp vec4 DirectionalLightSourceWorldSpaceDirection;
uniform highp vec4 SunDir;
uniform highp vec4 MoonDir;
uniform highp vec4 DimensionID;
uniform highp vec4 FogAndDistanceControl;
uniform highp vec4 FogColor;
uniform highp vec4 RenderChunkFogAlpha;
uniform highp vec4 Time;
uniform highp vec4 WorldOrigin;
uniform highp vec4 TimeOfDay;

SAMPLER2D_HIGHP_AUTOREG(s_PreviousFrameAverageLuminance);

#include "./lib/materials.glsl"
#include "./lib/shadow.glsl"
#include "./lib/bsdf.glsl"
#include "./lib/ibl.glsl"
#include "./lib/volumetrics.glsl"
#endif

void main() {
#if DEPTH_ONLY_PASS
    if (texture2D(s_MatTexture, v_texcoord0).a < 0.5) discard;
    vec3 ambientLight = texture2D(s_LightMapTexture, vec2(0.0, v_lightmapUV.y)).rgb;
    gl_FragData[0] = vec4(saturate(sqrt(v_lightColor + ambientLight * ambientLight)), 1.0);
#elif DEPTH_ONLY_OPAQUE_PASS
    vec3 ambientLight = texture2D(s_LightMapTexture, vec2(0.0, v_lightmapUV.y)).rgb;
    gl_FragData[0] = vec4(saturate(sqrt(v_lightColor + ambientLight * ambientLight)), 1.0);
#else

    //materials setup
    vec3 normal = gl_FrontFacing ? -v_normal : v_normal;
    normal = normalize(normal);
    vec4 mers = vec4(0.0, 0.0, 1.0, 0.0);
    getTexturePBRMaterials(s_MatTexture, v_pbrTextureId, v_texcoord0, v_tangent, v_bitangent, normal, mers);

    vec4 albedo = texture2D(s_MatTexture, v_texcoord0);

    //normalize vertex color to get rid ambient occlusion
    vec3 nColor = normalize(v_color0.rgb);
    float nColorAvg = colorAvg(nColor);

    //get vanilla ambient occlusion by using color average
    float vanillaAO = colorAvg(v_color0.rgb);

    albedo.rgb *= nColorAvg;
    albedo.rgb = toLinear(albedo.rgb);

    vec3 f0 = mix(vec3_splat(0.02), albedo.rgb, mers.r);

    //ambient lighting
    vec3 blockAmbient = v_lightColor;
    if ((blockAmbient.r + blockAmbient.g + blockAmbient.b) <= 0.0 && v_lightmapUV.r > 0.0) {
        float blm = v_lightmapUV.r * v_lightmapUV.r;
        blockAmbient = saturate(vec3(blm, blm * ((blm * 0.6 + 0.4) * 0.6 + 0.4), blm * ((blm * blm * 0.6) + 0.4)));
    }

    float skylmContrib = mix(pow(v_lightmapUV.g, 3.0), pow(v_lightmapUV.g, 5.0), CameraLightIntensity.g);
    if (int(DimensionID.r) == 1) skylmContrib = 0.05;
    if (int(DimensionID.r) == 2) skylmContrib = 0.02;
    vec3 skyAmbient = (v_scatterColor + v_absorbColor / SUN_MAX_ILLUMINANCE) * skylmContrib * SKY_AMBIENT_INTENSITY;

    vec3 ambientLight = max(blockAmbient * vanillaAO + skyAmbient * vanillaAO * vanillaAO, vec3_splat(MIN_AMBIENT_LIGHT));
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

    //water extinction
    bool isWaterBody = CausticsParameters.a > 0.0;

    if (int(DimensionID.r) == 0) {
        //reflections
        outColor += indirectSpecular(f0, worldDir, normal, blockAmbient, mers.b, mers.r, v_lightmapUV.g, !isWaterBody);

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
#endif //!DEPTH_ONLY_OPAQUE_PASS
}

#endif //BGFX_SHADER_TYPE_FRAGMENT
