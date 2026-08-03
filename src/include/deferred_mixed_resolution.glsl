#include "./lib/common.glsl"


///////////////////////////////////////////////////////////
// VERTEX SHADER
///////////////////////////////////////////////////////////
#if BGFX_SHADER_TYPE_VERTEX
#if FALLBACK_PASS
void main() {
    gl_Position = vec4_splat(0.0);
}
#else
uniform vec4 SunDir;
uniform vec4 MoonDir;
uniform vec4 DimensionID;

#include "./lib/atmosphere.glsl"

void main() {
    v_texcoord0 = a_texcoord0;
    v_projPos = a_position.xy * 2.0 - 1.0;

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

    gl_Position = vec4(a_position.xy * 2.0 - 1.0, a_position.z, 1.0);
}
#endif //!FALLBACK_PASS
#endif //BGFX_SHADER_TYPE_VERTEX






///////////////////////////////////////////////////////////
// FRAGMENT/PIXEL SHADER
///////////////////////////////////////////////////////////
#if BGFX_SHADER_TYPE_FRAGMENT
#if FALLBACK_PASS
void main() {
    gl_FragColor = vec4_splat(0.0);
}
#endif


#if CAUSTICS_MULTIPLIER_PASS
void main() {
    gl_FragData[0] = vec4(0.0, 1.0, 1.0, 1.0);
}
#endif


#if DIRECTIONAL_LIGHTING_PASS
uniform highp vec4 DirectionalLightSourceWorldSpaceDirection;
uniform highp vec4 Time;
uniform highp vec4 WorldOrigin;
uniform highp vec4 FogAndDistanceControl;

SAMPLER2D_HIGHP_AUTOREG(s_ColorMetalnessSubsurface);
SAMPLER2D_HIGHP_AUTOREG(s_Normal);
USAMPLER2D_AUTOREG(s_EmissiveAmbientLinearRoughness);
SAMPLER2D_HIGHP_AUTOREG(s_SceneDepth);
SAMPLER2D_HIGHP_AUTOREG(s_CausticsMultiplier);

#include "./lib/materials.glsl"
#include "./lib/shadow.glsl"
#include "./lib/bsdf.glsl"
#include "./lib/clouds.glsl"
#include "./lib/water_wave.glsl"

vec3 projToWorld(vec3 projPos) {
    vec4 worldPos = mul(u_invViewProj, vec4(projPos, 1.0));
    return worldPos.xyz / worldPos.w;
}

void main() {
    float depth = sampleDepth(s_SceneDepth, v_texcoord0);
    vec3 worldPos = projToWorld(vec3(v_projPos, depth));
    vec3 worldDir = normalize(worldPos);
    vec3 position = worldPos - WorldOrigin.xyz;

    //materials data from gbuffers
    uvec4 data16 = texelFetch(s_EmissiveAmbientLinearRoughness, ivec2(gl_FragCoord.xy), 0) & 0xFFFFu;
    float roughness = float(data16.r >> 8) / 255.0;
    float emssive = float(data16.r & 0xFFu) / 255.0;
    vec4 data = texture2D(s_ColorMetalnessSubsurface, v_texcoord0);
    float metalness = unpackMetalness(data.a);
    float subsurface = unpackSubsurface(data.a);
    subsurface *= linearstep(55.0, 50.0, length(worldPos));
    vec3 albedo = toLinear(data.rgb);
    vec3 f0 = mix(vec3_splat(0.02), albedo, metalness);
    vec3 normal = octToNdirSnorm(texture2D(s_Normal, v_texcoord0).rg);

    vec3 shadowMap = calcShadowMap(worldPos, normal).rgr;

#ifdef VOLUMETRIC_CLOUDS_ENABLED
    CloudSetup cloudSetup = calcCloudSetup(DirectionalLightSourceWorldSpaceDirection.y, position.y);
    float cloudShadow = calcCloudShadow(position, DirectionalLightSourceWorldSpaceDirection.xyz, 2.0, cloudSetup);
    shadowMap.rg = min(shadowMap.rg, vec2_splat(cloudShadow * CLOUD_SHADOW_CONTRIBUTION + (1.0 - CLOUD_SHADOW_CONTRIBUTION)));
    shadowMap.b = min(shadowMap.b, cloudShadow); //used for specular
#endif

    float waterBodyMask = texture2D(s_CausticsMultiplier, v_texcoord0).r;
    if (waterBodyMask < 1.0) {
        float caustic = calcCaustic(position, DirectionalLightSourceWorldSpaceDirection.xyz, Time.x);
        shadowMap = (FogAndDistanceControl.r < EPSILON) ? shadowMap * (caustic * 2.4 + 0.1) : shadowMap * (caustic * 2.0 + 0.5);
    }

    vec3 bsdf = BSDF(normal, DirectionalLightSourceWorldSpaceDirection.xyz, -worldDir, f0, albedo, shadowMap, metalness, roughness, subsurface);
    vec3 alwaysLit = albedo * emssive * EMISSIVE_MATERIAL_INTENSITY;

    gl_FragData[0] = depth < 1.0 ? vec4(v_absorbColor * bsdf + alwaysLit, 1.0) : vec4_splat(0.0);
    gl_FragData[1] = vec4(waterBodyMask, 0.0, 0.0, 1.0);
}

#endif //DIRECTIONAL_LIGHTING_PASS


#if DISCRETE_INDIRECT_COMBINED_LIGHTING_PASS
uniform highp vec4 CameraLightIntensity;
uniform highp vec4 DimensionID;

SAMPLER2D_HIGHP_AUTOREG(s_ColorMetalnessSubsurface);
USAMPLER2D_AUTOREG(s_EmissiveAmbientLinearRoughness);

#include "./lib/materials.glsl"
#include "./lib/atmosphere.glsl"

void main() {
    uvec4 data16 = texelFetch(s_EmissiveAmbientLinearRoughness, ivec2(gl_FragCoord.xy), 0) & 0xFFFFu;
    vec4 blightColor = vec4(data16.g >> 8, data16.g & 0xFFu, data16.b >> 8, data16.b & 0xFFu) / 255.0;
    float skyLightmap = float(data16.a & 0xFFu) / 255.0;
    float vanillaAO = float(data16.a >> 8) / 255.0; //baked ambient occlusion from gbufffers
    vec4 data = texture2D(s_ColorMetalnessSubsurface, v_texcoord0);
    vec3 albedo = toLinear(data.rgb);
    float metalness = unpackMetalness(data.a);

    vec3 blockAmbient = blightColor.rgb * blightColor.a * 6.0;

    float skylmContrib = mix(pow(skyLightmap, 3.0), pow(skyLightmap, 5.0), CameraLightIntensity.y);
    if (int(DimensionID.r) == 1) skylmContrib = 0.05; //nether
    if (int(DimensionID.r) == 2) skylmContrib = 0.02; //end world
    vec3 skyAmbient = (v_scatterColor + v_absorbColor / SUN_MAX_ILLUMINANCE) * skylmContrib * SKY_AMBIENT_INTENSITY;

    vec3 ambientLight = max(blockAmbient * vanillaAO + skyAmbient * vanillaAO * vanillaAO, vec3_splat(MIN_AMBIENT_LIGHT));
    vec3 outColor = ambientLight * albedo * (1.0 - metalness);

    gl_FragData[0] = vec4_splat(0.0);
    gl_FragData[1] = vec4(outColor, 1.0); //this will be added to s_DiffuseLighting
    gl_FragData[2] = vec4_splat(0.0);
}

#endif //DISCRETE_INDIRECT_COMBINED_LIGHTING_PASS


#if SURFACE_RADIANCE_UPSCALE_PASS
uniform highp vec4 CameraLightIntensity;
uniform highp vec4 DimensionID;
uniform highp vec4 FogColor;
uniform highp vec4 SunDir;
uniform highp vec4 MoonDir;
uniform highp vec4 DirectionalLightSourceWorldSpaceDirection;
uniform highp vec4 Time;
uniform highp vec4 FogAndDistanceControl;
uniform highp vec4 RenderChunkFogAlpha;
uniform highp vec4 WorldOrigin;

SAMPLER2D_HIGHP_AUTOREG(s_SceneDepth);
SAMPLER2D_HIGHP_AUTOREG(s_DiffuseLighting);
SAMPLER2D_HIGHP_AUTOREG(s_SpecularLighting);
SAMPLER2D_HIGHP_AUTOREG(s_PreviousFrameAverageLuminance);

#include "./lib/materials.glsl"
#include "./lib/atmosphere.glsl"
#include "./lib/volumetrics.glsl"

vec3 projToWorld(vec3 projPos) {
    vec4 worldPos = mul(u_invViewProj, vec4(projPos, 1.0));
    return worldPos.xyz / worldPos.w;
}

void main() {
    float depth = sampleDepth(s_SceneDepth, v_texcoord0);
    vec3 projPos = vec3(v_projPos, depth);
    vec3 worldPos = projToWorld(projPos);
    vec3 worldDir = normalize(worldPos);
    float worldDist = length(worldPos);
    float wDistNorm = worldDist / FogAndDistanceControl.z;

    vec3 outColor = vec3_splat(0.0);

    bool isTerrain = depth < 1.0;

    //sky atmosphere params
    AtmosphereParams sunAtmParams;
    sunAtmParams.rayStart = vec3(0.0, 10.0, 0.0);
    sunAtmParams.rayDir = worldDir;
    sunAtmParams.lightDir = SunDir.xyz;
    sunAtmParams.rayLength = 1e10;
    sunAtmParams.aerial = 1.0;
    sunAtmParams.occlusion = 1.0;
    sunAtmParams.mieMod = 1.0;

    AtmosphereParams moonAtmParams;
    moonAtmParams.rayStart = vec3(0.0, 10.0, 0.0);
    moonAtmParams.rayDir = worldDir;
    moonAtmParams.lightDir = MoonDir.xyz;
    moonAtmParams.rayLength = 1e10;
    moonAtmParams.aerial = 1.0;
    moonAtmParams.occlusion = 1.0;
    moonAtmParams.mieMod = 1.0;

    if (isTerrain) outColor = texture2D(s_DiffuseLighting, v_texcoord0).rgb;

    bool isWaterBody = texture2D(s_SpecularLighting, v_texcoord0).r < 1.0;
    bool isCameraUnderwater = FogAndDistanceControl.r < EPSILON;
    // bool isCameraUnderlava = FogAndDistanceControl.r > 0.4 && FogAndDistanceControl.r < 0.6;

    if (int(DimensionID.r) == 0) {
        //sky
        vec3 scattering = GetAtmosphere(sunAtmParams) * SUN_MAX_ILLUMINANCE;
        scattering += GetAtmosphere(moonAtmParams) * MOON_MAX_ILLUMINANCE;
        if (!isTerrain) outColor = scattering;

        applyCirrusClouds(outColor, worldDir, DirectionalLightSourceWorldSpaceDirection.xyz, v_absorbColor, isTerrain);

#ifdef VOLUMETRIC_CLOUDS_ENABLED
        float dither = texelFetch(s_CausticsTexture, ivec3(ivec2(gl_FragCoord.xy) % 256, 1), 0).r;
        applyCumulusClouds(outColor, v_absorbColor, worldDir, worldDist, dither, isTerrain);
#endif

        //underwater extinction and scattering
        if (isWaterBody && isCameraUnderwater) {
            outColor *= exp(-WATER_EXTINCTION_COEFFICIENTS * worldDist);
            vec3 wscattering = exp(-WATER_EXTINCTION_COEFFICIENTS * 10.0) * luminance(v_absorbColor) * CameraLightIntensity.y;
            outColor = mix(outColor, wscattering, 0.01);
        }

        applyVolumetricFog(outColor, projPos);
    } else {
        float borderFog = saturate((wDistNorm + RenderChunkFogAlpha.x - FogAndDistanceControl.x) * FogAndDistanceControl.y);
        vec3 linFogColor = toLinear(FogColor.rgb);
        outColor = mix(outColor, linFogColor, borderFog);
    }

    outColor = preExposeLighting(outColor, texture2D(s_PreviousFrameAverageLuminance, vec2_splat(0.5)).r);

    gl_FragColor = vec4(outColor, 1.0);
}
#endif //SURFACE_RADIANCE_UPSCALE_PASS

#endif //BGFX_SHADER_TYPE_FRAGMENT
