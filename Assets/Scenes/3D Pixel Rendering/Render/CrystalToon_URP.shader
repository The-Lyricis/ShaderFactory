Shader "Pixel/CrystalToon_URP"
{
    Properties
    {
        [Header(Base Appearance)]
        _BaseMap("Base Texture (Internal Detail)", 2D) = "white" {}
        _BaseColor("Crystal Tint", Color) = (1,1,1,1)

        [Header(Transparency Fresnel)]
        _Opacity("Opacity (Surface Mix)", Range(0, 1)) = 0.55
        _FresnelPower("Fresnel Power", Range(0.5, 10)) = 4
        _FresnelStrength("Fresnel Strength", Range(0, 2)) = 1.0

        [Header(Refraction)]
        _RefractionStrength("Refraction Strength", Range(0, 0.2)) = 0.05
        _ChromaticAberration("Chromatic Aberration", Range(0, 0.05)) = 0.01
        [Toggle(_CRYSTAL_ABERRATION)] _EnableAberration("Enable Aberration (3x Scene Samples)", Float) = 0

        [Header(BeerLambert)]
        _AbsorptionColor("Absorption Color", Color) = (0.2, 0.6, 1.0, 1)
        _AbsorptionDensity("Absorption Density", Range(0, 10)) = 2.0
        _ThicknessMin("Thickness Min", Range(0, 2)) = 0.1
        _ThicknessMax("Thickness Max", Range(0, 8)) = 2.0
        _ThicknessPower("Thickness Power", Range(0.5, 8)) = 2.0

        [Header(Internal Facets)]
        _FacetMap("Facet Texture (Noise)", 2D) = "white" {}
        _FacetScale("Facet Scale", Range(0.1, 20)) = 3.0
        _FacetStrength("Facet Strength", Range(0, 3)) = 1.2
        _FacetSharpness("Facet Sharpness", Range(0.5, 8)) = 3.0
        [Toggle(_CRYSTAL_TRIPLANAR)] _FacetTriplanar("Facet Triplanar", Float) = 1

        [Header(Toon Lighting)]
        _Steps("Toon Steps", Range(1,5)) = 3
        _RampSmooth("Step Smoothness", Range(0,1)) = 0.05
        _ShadowTint("Shadow Tint", Color) = (0.5, 0.5, 0.6, 1)
        _ShadowDarkness("Shadow Darkness", Range(0,1)) = 0.5

        [Header(MultiLights Controls)]
        _AdditionalIntensity("Additional Lights Intensity", Range(0,2)) = 1.0
        _AdditionalSpecMul("Additional Spec Mul", Range(0,1)) = 0.5
        _AdditionalRimMul("Additional Rim Mul", Range(0,1)) = 0.5

        [Header(Specular Reflection Rim)]
        _SpecColor("Specular Color", Color) = (1,1,1,1)
        _SpecPower("Specular Power", Range(1,128)) = 64
        _SpecThreshold("Spec Threshold", Range(0,1)) = 0.6

        [Toggle(_CRYSTAL_USE_SCENECOLOR)] _UseSceneColor("Use Scene Color Refraction", Float) = 1
        _ReflectionStrength("Env Reflection Strength", Range(0, 2)) = 0.8
        _Roughness("Reflection Roughness", Range(0,1)) = 0.15

        _RimColor("Rim Color", Color) = (1,1,1,1)
        _RimPower("Rim Power", Range(0.5,8)) = 4
        _RimThreshold("Rim Threshold", Range(0,1)) = 0.5

        [Header(Depth Sorting)]
        [Toggle] _DepthPrepass("Depth Prepass", Float) = 1
        [Toggle] _ZWriteInForward("ZWrite In Forward (Debug)", Float) = 0
    }

    SubShader
    {
        Tags
        {
            "RenderPipeline"="UniversalPipeline"
            "Queue"="Transparent"
            "RenderType"="Transparent"
        }

        HLSLINCLUDE
        // Keep only declarations/common helpers; avoid includes like Fog.hlsl that can re-define.
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

        // -------- Shared textures/samplers --------
        TEXTURE2D(_BaseMap);  SAMPLER(sampler_BaseMap);
        TEXTURE2D(_FacetMap); SAMPLER(sampler_FacetMap);

        // -------- Shared material CBUFFER --------
        // Shared uniforms for ForwardLit and CrystalBack.
        // Extra fields are ok (unused ones get stripped), missing ones will cause errors.
        CBUFFER_START(UnityPerMaterial)
            float4 _BaseMap_ST;
            float4 _BaseColor;

            float _Opacity;
            float _FresnelPower;
            float _FresnelStrength;

            float _RefractionStrength;
            float _ChromaticAberration;

            float4 _AbsorptionColor;
            float _AbsorptionDensity;
            float _ThicknessMin;
            float _ThicknessMax;
            float _ThicknessPower;

            float _FacetScale;
            float _FacetStrength;
            float _FacetSharpness;

            float _Steps;
            float _RampSmooth;
            float4 _ShadowTint;
            float _ShadowDarkness;

            float _AdditionalIntensity;
            float _AdditionalSpecMul;
            float _AdditionalRimMul;

            float4 _SpecColor;
            float _SpecPower;
            float _SpecThreshold;

            float _ReflectionStrength;
            float _Roughness;

            float4 _RimColor;
            float _RimPower;
            float _RimThreshold;

            float _DepthPrepass;
            float _ZWriteInForward;
        CBUFFER_END

        // -------- Shared helper functions --------
        half ToonRamp(half x, half steps, half smooth)
        {
            half s  = max(steps, 1.0h);
            half xs = x * s;

            half q0 = floor(xs) / s;
            if (smooth <= 0.0h) return q0;

            half q1 = (floor(xs) + 1.0h) / s;
            half t  = frac(xs);
            half k  = smoothstep(0.5h - smooth, 0.5h + smooth, t);
            return lerp(q0, q1, k);
        }

        // Triplanar facet sampling (CrystalBack/ForwardLit).
        half SampleFacetTriplanar(float3 posWS, float3 nWS)
        {
            float3 w = pow(abs(nWS), 6.0);
            w /= max(w.x + w.y + w.z, 1e-5);

            float2 uvX = posWS.zy * _FacetScale;
            float2 uvY = posWS.xz * _FacetScale;
            float2 uvZ = posWS.xy * _FacetScale;

            half fx = SAMPLE_TEXTURE2D(_FacetMap, sampler_FacetMap, uvX).r;
            half fy = SAMPLE_TEXTURE2D(_FacetMap, sampler_FacetMap, uvY).r;
            half fz = SAMPLE_TEXTURE2D(_FacetMap, sampler_FacetMap, uvZ).r;

            return fx * w.x + fy * w.y + fz * w.z;
        }
        ENDHLSL


        // -----------------------------
        // Depth prepass for transparency stability
        // -----------------------------
        Pass
        {
            Name "DepthOnly"
            Tags { "LightMode"="DepthOnly" }

            ZWrite On
            ColorMask 0

            HLSLPROGRAM
            #pragma vertex vertDepth
            #pragma fragment fragDepth
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            struct Attributes { float4 positionOS : POSITION; };
            struct Varyings  { float4 positionCS : SV_POSITION; };

            Varyings vertDepth(Attributes IN)
            {
                Varyings OUT;
                VertexPositionInputs pos = GetVertexPositionInputs(IN.positionOS.xyz);
                OUT.positionCS = pos.positionCS;
                return OUT;
            }

            half4 fragDepth(Varyings IN) : SV_Target
            {
                clip(_DepthPrepass - 0.5);
                return 0;
            }
            ENDHLSL
        }

        Pass
        {
            Name "CrystalBack"
            Tags { "LightMode"="CrystalBack" }

            // Render backfaces only (interior).
            Cull Front

            // Do not write depth to avoid sealing the interior.
            ZWrite Off

            // Use current low-res depth (opaque depth) to prevent see-through.
            ZTest LEqual

            Blend SrcAlpha OneMinusSrcAlpha

            HLSLPROGRAM
            #pragma vertex vertBack
            #pragma fragment fragBack

            // Shadow and additional light variants (trim if unused).
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE
            #pragma multi_compile_fragment _ _SHADOWS_SOFT
            #pragma multi_compile_fragment _ _ADDITIONAL_LIGHTS
            #pragma multi_compile_fragment _ _ADDITIONAL_LIGHT_SHADOWS

            // Match feature toggles with the main pass.
            #pragma shader_feature_local _CRYSTAL_TRIPLANAR

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            // Notes:
            // - Do not include DeclareOpaqueTexture or SampleSceneColor to avoid double refraction.
            // - This pass only adds interior contribution for backfaces.

            // ---------- Same structure as the main pass ----------
            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
                float2 uv         : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionCS  : SV_POSITION;
                float3 positionWS  : TEXCOORD0;
                float3 normalWS    : TEXCOORD1;
                float3 viewDirWS   : TEXCOORD2;
                float4 shadowCoord : TEXCOORD3;
            };


            Varyings vertBack(Attributes IN)
            {
                Varyings OUT;

                VertexPositionInputs pos = GetVertexPositionInputs(IN.positionOS.xyz);
                VertexNormalInputs   nor = GetVertexNormalInputs(IN.normalOS);

                OUT.positionCS = pos.positionCS;
                OUT.positionWS = pos.positionWS;
                OUT.normalWS   = normalize(nor.normalWS);
                OUT.viewDirWS  = GetWorldSpaceViewDir(pos.positionWS);

                // Allow interior faces to receive main light shadows (optional).
                OUT.shadowCoord = GetShadowCoord(pos);

                return OUT;
            }

            half4 fragBack(Varyings IN) : SV_Target
            {
                half3 V = normalize(IN.viewDirWS);

                // Backface pass still uses outward normals.
                // Flip normals so the interior faces light toward the camera.
                half3 N = -normalize(IN.normalWS);

                half NoV = saturate(dot(N, V));

                // ---------- Thickness approximation (grazing is thicker) ----------
                half thicknessT = pow(1.0h - NoV, _ThicknessPower);
                half thickness  = lerp(_ThicknessMin, _ThicknessMax, thicknessT);

                // ---------- Beer-Lambert absorption (deeper interior) ----------
                half3 absorption    = _AbsorptionColor.rgb * _AbsorptionDensity;
                half3 transmittance = exp(-absorption * thickness);

                // ---------- Interior facets ----------
                half facetNoise;
                #if defined(_CRYSTAL_TRIPLANAR)
                    facetNoise = SampleFacetTriplanar((float3)IN.positionWS, (float3)N);
                #else
                    float2 facetUV = IN.positionWS.xz * _FacetScale;
                    facetNoise = SAMPLE_TEXTURE2D(_FacetMap, sampler_FacetMap, facetUV).r;
                #endif

                half facet = pow(saturate(facetNoise), _FacetSharpness) * _FacetStrength;

                // ---------- Main light (interior diffuse + shadows) ----------
                Light mainLight = GetMainLight(IN.shadowCoord);
                half3 L = normalize(mainLight.direction);

                half ndl   = saturate(dot(N, L));
                half ramp  = ToonRamp(ndl, _Steps, _RampSmooth);
                half shadowAtten = mainLight.shadowAttenuation;

                // Interior diffuse favors internal glow; avoid _ShadowTint to keep it clean.
                half3 diffuse = _BaseColor.rgb * ramp * mainLight.color * shadowAtten;

                // ---------- Interior specular (thresholded edge sparkle) ----------
                half3 H = normalize(L + V);
                half specRaw = pow(saturate(dot(N, H)), _SpecPower);
                half spec    = step(_SpecThreshold, specRaw);
                half3 specular = spec * _SpecColor.rgb * mainLight.color * shadowAtten;

                // ---------- Interior rim (makes backface silhouette visible) ----------
                half rimRaw = pow(1.0h - NoV, _RimPower);
                half rim    = step(_RimThreshold, rimRaw);
                half3 rimCol = rim * _RimColor.rgb * mainLight.color;

                // ---------- Composite: diffuse + facets + specular + rim ----------
                // Transmittance darkens thicker regions for a crystal look.
                half3 internalCol = diffuse * transmittance;

                // Facet sparkle is less attenuated to keep bright flecks.
                internalCol += facet * _BaseColor.rgb * (0.35h + 0.65h * shadowAtten) * mainLight.color;

                internalCol += (specular + rimCol) * (0.5h + 0.5h * facet);

                // ---------- Alpha: interior contribution scales with transparency ----------
                // Lower _Opacity (more transparent) makes the interior stronger.
                half alpha = saturate((1.0h - _Opacity) * 0.85h);
                // Boost interior presence at grazing angles.
                alpha = saturate(alpha + (1.0h - NoV) * 0.15h);

                return half4(internalCol, alpha);
            }
            ENDHLSL
        }


        // -----------------------------
        // Forward pass
        // -----------------------------
        Pass
        {
            Name "ForwardLit"
            Tags { "LightMode"="UniversalForward" }

            ZTest LEqual
            ZWrite Off
            Blend SrcAlpha OneMinusSrcAlpha

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_fog

            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE
            #pragma multi_compile_fragment _ _SHADOWS_SOFT
            #pragma multi_compile_fragment _ _ADDITIONAL_LIGHTS
            #pragma multi_compile_fragment _ _ADDITIONAL_LIGHT_SHADOWS

            #pragma shader_feature_local _CRYSTAL_ABERRATION
            #pragma shader_feature_local _CRYSTAL_TRIPLANAR
            #pragma shader_feature_local _CRYSTAL_USE_SCENECOLOR


            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareOpaqueTexture.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/ImageBasedLighting.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
                float2 uv         : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionCS  : SV_POSITION;
                float2 uv          : TEXCOORD0;
                float4 screenPos   : TEXCOORD1;
                float3 normalWS    : TEXCOORD2;
                float3 viewDirWS   : TEXCOORD3;
                float3 positionWS  : TEXCOORD4;
                float4 shadowCoord : TEXCOORD5;
                half   fogFactor   : TEXCOORD6;
            };

            // -------- Core: unified toon evaluation for multiple lights --------
            void EvaluateToonLight(
                Light li,
                half3 N,
                half3 V,
                half3 baseTint,              // _BaseColor.rgb
                half  isAdditional,          // 0=main, 1=additional
                out half3 diffuseOut,
                out half3 specOut,
                out half3 rimOut
            )
            {
                half3 L = normalize(li.direction);

                // Diffuse band
                half ndl  = saturate(dot(N, L));
                half ramp = ToonRamp(ndl, (half)_Steps, (half)_RampSmooth);

                // Shadow blend (stable and controllable).
                // shadowAttenuation: 1=lit, 0=shadow.
                half sh = (half)li.shadowAttenuation;
                half shadowAmount = (1.0h - sh) * (half)_ShadowDarkness;  // 0..ShadowDarkness

                // Point/spot attenuation via distanceAttenuation.
                half atten = (half)li.distanceAttenuation;
                // Main light distance attenuation is usually 1.
                half lightScale = lerp(1.0h, (half)_AdditionalIntensity, isAdditional);

                half3 litCol    = baseTint * ramp;                 // toon lit
                half3 shadowCol = litCol * (half3)_ShadowTint.rgb; // tinted shadow
                half3 diff      = lerp(litCol, shadowCol, shadowAmount);

                diffuseOut = diff * (half3)li.color * atten * lightScale;

                // Specular (banded)
                half3 H = normalize(L + V);
                half spRaw  = pow(saturate(dot(N, H)), (half)_SpecPower);
                half spBand = step((half)_SpecThreshold, spRaw);

                half specMul = lerp(1.0h, (half)_AdditionalSpecMul, isAdditional);
                specOut = spBand * (half3)_SpecColor.rgb * (half3)li.color * sh * atten * lightScale * specMul;

                // Rim (banded) is view-based but keeps light color/attenuation.
                half NoV = saturate(dot(N, V));
                half rimRaw  = pow(1.0h - NoV, (half)_RimPower);
                half rimBand = step((half)_RimThreshold, rimRaw);

                half rimMul = lerp(1.0h, (half)_AdditionalRimMul, isAdditional);
                rimOut = rimBand * (half3)_RimColor.rgb * (half3)li.color * atten * lightScale * rimMul;
            }
            half LightEnergy01(half3 c)
            {
                // Simple luminance estimate.
                return saturate(dot(c, half3(0.2126h, 0.7152h, 0.0722h)));
            }

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                VertexPositionInputs pos = GetVertexPositionInputs(IN.positionOS.xyz);
                VertexNormalInputs   nor = GetVertexNormalInputs(IN.normalOS);

                OUT.positionCS  = pos.positionCS;
                OUT.positionWS  = pos.positionWS;
                OUT.uv          = TRANSFORM_TEX(IN.uv, _BaseMap);
                OUT.normalWS    = normalize(nor.normalWS);
                OUT.viewDirWS   = GetWorldSpaceViewDir(pos.positionWS);
                OUT.screenPos   = ComputeScreenPos(OUT.positionCS);
                OUT.shadowCoord = GetShadowCoord(pos);
                OUT.fogFactor   = ComputeFogFactor(OUT.positionCS.z);
                return OUT;
            }

            half4 frag(Varyings IN) : SV_Target
            {
                half3 N = normalize(IN.normalWS);
                half3 V = normalize(IN.viewDirWS);

                float2 screenUV = IN.screenPos.xy / max(IN.screenPos.w, 1e-5);

                // -----------------------------
                // 1) Refraction (Scene Color)
                // -----------------------------
                float2 refractOffset = (float2)N.xy * _RefractionStrength;

                half3 refractedColor;
                #if defined(_CRYSTAL_ABERRATION)
                    half r = SampleSceneColor(screenUV + refractOffset).r;
                    half g = SampleSceneColor(screenUV + refractOffset * (1.0 + _ChromaticAberration)).g;
                    half b = SampleSceneColor(screenUV + refractOffset * (1.0 + _ChromaticAberration * 2.0)).b;
                    refractedColor = half3(r, g, b);
                #else
                    refractedColor = SampleSceneColor(screenUV + refractOffset);
                #endif

                // -----------------------------
                // 2) Internal facets
                // -----------------------------
                half facetNoise;
                #if defined(_CRYSTAL_TRIPLANAR)
                    facetNoise = SampleFacetTriplanar((float3)IN.positionWS, (float3)N);
                #else
                    float2 facetUV = (IN.positionWS.xz) * _FacetScale;
                    facetNoise = SAMPLE_TEXTURE2D(_FacetMap, sampler_FacetMap, facetUV).r;
                #endif
                half facet = pow(saturate(facetNoise), _FacetSharpness) * _FacetStrength;

                // -----------------------------
                // 3) Fresnel + Absorption
                // -----------------------------
                half NoV = saturate(dot(N, V));
                half fresnel = pow(1.0h - NoV, _FresnelPower) * _FresnelStrength;

                half thicknessT = pow(1.0h - NoV, _ThicknessPower);
                half thickness  = lerp(_ThicknessMin, _ThicknessMax, thicknessT);

                half3 absorption    = _AbsorptionColor.rgb * _AbsorptionDensity;
                half3 transmittance = exp(-absorption * thickness);

                // -----------------------------
                // 4) Lighting: main + additional (unified).
                // -----------------------------
                half3 baseTint = (half3)_BaseColor.rgb;

                // Main
                Light mainLight = GetMainLight(IN.shadowCoord);
                half3 diffM, specM, rimM;
                EvaluateToonLight(mainLight, N, V, baseTint, 0.0h, diffM, specM, rimM);

                half3 diffA = 0, specA = 0, rimA = 0;
                #if defined(_ADDITIONAL_LIGHTS)
                {
                    uint count = GetAdditionalLightsCount();
                    for (uint li = 0u; li < count; li++)
                    {
                        Light l = GetAdditionalLight(li, IN.positionWS);
                        half3 d2, s2, r2;
                        EvaluateToonLight(l, N, V, baseTint, 1.0h, d2, s2, r2);
                        diffA += d2;
                        specA += s2;
                        rimA  += r2;
                    }
                }
                #endif

                half3 surfaceLit = (diffM + diffA) + (specM + specA) + (rimM + rimA);
                half lightE = LightEnergy01(surfaceLit);          // 0..1
                // Optional: make it harder.
                lightE = step(0.02h, lightE);  
                refractedColor *= lightE;     // No light -> perceived black (no background bleed).
                // -----------------------------
                // 5) Env reflection (IBL)
                // -----------------------------
                half3 R = reflect(-V, N);
                half perceptualRoughness = saturate(_Roughness);
                half3 envRefl = GlossyEnvironmentReflection(R, perceptualRoughness, 1.0h);
                envRefl *= (_ReflectionStrength * saturate(fresnel));
                envRefl        *= lightE;     // No light -> no reflection.
                // -----------------------------
                // 6) Internal facet sparkle (lightweight).
                // -----------------------------
                // Drive with overall light energy (avoid only main light).
                half3 approxLightColor = (half3)mainLight.color;
                #if defined(_ADDITIONAL_LIGHTS)
                    approxLightColor += 0.25h; // Small lift to avoid darkness with zero lights.
                #endif
                half3 internalFacet = facet * baseTint * approxLightColor;
                internalFacet  *= lightE;     // No light -> no sparkle.
                // -----------------------------
                // 7) Composite
                // -----------------------------
                // Surface/refraction mix (_Opacity is the surface weight).
                half3 baseMix = lerp(refractedColor, surfaceLit, (half)_Opacity);

                // Absorption (approximate).
                half3 absorbed = baseMix * transmittance;

                // Add reflection + facets.
                half3 finalRGB = absorbed + envRefl + internalFacet;

                // Alpha output: for true transparency, bind alpha to _Opacity.
                // If you want visual transparency but alpha=1, set it to 1.
                half alphaOut = saturate((half)_Opacity);

                half4 outCol = half4(finalRGB, alphaOut);
                outCol.rgb = MixFog(outCol.rgb, IN.fogFactor);
                return outCol;
            }
            ENDHLSL
        }

        UsePass "Universal Render Pipeline/Lit/ShadowCaster"
    }
}
