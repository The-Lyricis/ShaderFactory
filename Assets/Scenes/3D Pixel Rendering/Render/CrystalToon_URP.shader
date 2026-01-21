Shader "Pixel/CrystalToon_URP"
{
    Properties
    {
        [Header(Base Appearance)]
        _BaseMap("Base Texture (Internal Detail)", 2D) = "white" {}
        _BaseColor("Crystal Tint", Color) = (1,1,1,1)

        [Header(Transparency Fresnel)]
        _Opacity("Opacity (Overall Alpha)", Range(0, 1)) = 0.55
        _SurfaceWeight("Surface Weight (Lit vs Refract)", Range(0, 1)) = 0.55
        _FresnelPower("Fresnel Power", Range(0.5, 10)) = 4
        _FresnelStrength("Fresnel Strength", Range(0, 2)) = 1.0

        [Header(Refraction)]
        [Toggle(_CRYSTAL_USE_SCENECOLOR)] _UseSceneColor("Use Scene Color Refraction", Float) = 1
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
        #pragma target 3.0
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

        // -------- Shared textures/samplers --------
        TEXTURE2D(_BaseMap);  SAMPLER(sampler_BaseMap);
        TEXTURE2D(_FacetMap); SAMPLER(sampler_FacetMap);

        // -------- Shared material CBUFFER (ForwardLit & CrystalBack 共用) --------
        CBUFFER_START(UnityPerMaterial)
            float4 _BaseMap_ST;
            float4 _BaseColor;

            float _Opacity;
            float _SurfaceWeight;
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

        // -------- Helpers --------
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

        // faster-ish pow for [0,1]
        half PowFast01(half a, half p)
        {
            return exp2(p * log2(max(a, 1e-4h)));
        }

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

        half LightEnergy01(half3 c)
        {
            return saturate(dot(c, half3(0.2126h, 0.7152h, 0.0722h)));
        }

        ENDHLSL

        // -----------------------------
        // Depth prepass (DepthOnly)
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
                if (_DepthPrepass < 0.5) discard;
                return 0;
            }
            ENDHLSL
        }

        // -----------------------------
        // Crystal backfaces (interior)
        // -----------------------------
        Pass
        {
            Name "CrystalBack"
            Tags { "LightMode"="CrystalBack" }

            Cull Front
            ZWrite Off
            ZTest LEqual
            Blend SrcAlpha OneMinusSrcAlpha

            HLSLPROGRAM
            #pragma vertex vertBack
            #pragma fragment fragBack

            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE
            #pragma multi_compile_fragment _ _SHADOWS_SOFT
            #pragma multi_compile_fragment _ _ADDITIONAL_LIGHTS
            // 建议：不启用 additional light shadows，透明一般不需要
            // #pragma multi_compile_fragment _ _ADDITIONAL_LIGHT_SHADOWS

            #pragma shader_feature_local _CRYSTAL_TRIPLANAR

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
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
                OUT.shadowCoord = GetShadowCoord(pos);
                return OUT;
            }

            half4 fragBack(Varyings IN) : SV_Target
            {
                half3 V = normalize(IN.viewDirWS);

                // flip outward normal for interior lighting
                half3 N = -normalize(IN.normalWS);

                half NoV = saturate(dot(N, V));
                half invNoV = saturate(1.0h - NoV);

                // thickness
                half thicknessT = pow(invNoV, _ThicknessPower);
                half thickness  = lerp(_ThicknessMin, _ThicknessMax, thicknessT);

                // absorption
                half3 absorption    = _AbsorptionColor.rgb * _AbsorptionDensity;
                half3 transmittance = exp(-absorption * thickness);

                // facet (early out)
                half facet = 0;
                if (_FacetStrength > 1e-3)
                {
                    half facetNoise;
                    #if defined(_CRYSTAL_TRIPLANAR)
                        facetNoise = SampleFacetTriplanar((float3)IN.positionWS, (float3)N);
                    #else
                        float2 facetUV = IN.positionWS.xz * _FacetScale;
                        facetNoise = SAMPLE_TEXTURE2D(_FacetMap, sampler_FacetMap, facetUV).r;
                    #endif

                    facet = PowFast01(saturate(facetNoise), _FacetSharpness) * _FacetStrength;
                }

                // main light
                Light mainLight = GetMainLight(IN.shadowCoord);
                half3 L = normalize(mainLight.direction);
                half ndl = saturate(dot(N, L));
                half ramp = ToonRamp(ndl, _Steps, _RampSmooth);
                half sh = mainLight.shadowAttenuation;

                half3 diffuse = _BaseColor.rgb * ramp * mainLight.color * sh;

                // spec
                half3 H = normalize(L + V);
                half specRaw = pow(saturate(dot(N, H)), _SpecPower);
                half spec    = step(_SpecThreshold, specRaw);
                half3 specular = spec * _SpecColor.rgb * mainLight.color * sh;

                // rim
                half rimRaw = pow(invNoV, _RimPower);
                half rim    = step(_RimThreshold, rimRaw);
                half3 rimCol = rim * _RimColor.rgb * mainLight.color;

                // composite
                half3 internalCol = diffuse * transmittance;
                internalCol += facet * _BaseColor.rgb * (0.35h + 0.65h * sh) * mainLight.color;
                internalCol += (specular + rimCol) * (0.5h + 0.5h * facet);

                // ---- Alpha semantics (更直觉) ----
                // _Opacity 越高整体越不透明 => interior 越弱
                half alphaOut = saturate(_Opacity);
                half interiorAlpha = (1.0h - alphaOut);
                interiorAlpha *= saturate(0.85h + invNoV * 0.15h);

                return half4(internalCol, interiorAlpha);
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

            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE
            #pragma multi_compile_fragment _ _SHADOWS_SOFT
            #pragma multi_compile_fragment _ _ADDITIONAL_LIGHTS
            // #pragma multi_compile_fragment _ _ADDITIONAL_LIGHT_SHADOWS

            #pragma shader_feature_local _CRYSTAL_ABERRATION
            #pragma shader_feature_local _CRYSTAL_TRIPLANAR
            #pragma shader_feature_local _CRYSTAL_USE_SCENECOLOR

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            // SampleSceneColor 需要 OpaqueTexture 支持；保留 include，但通过 keyword 控制是否真的采样
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareOpaqueTexture.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/ImageBasedLighting.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
            };

            struct Varyings
            {
                float4 positionCS  : SV_POSITION;
                float4 screenPos   : TEXCOORD0;
                float3 normalWS    : TEXCOORD1;
                float3 viewDirWS   : TEXCOORD2;
                float3 positionWS  : TEXCOORD3;
                float4 shadowCoord : TEXCOORD4;
            };

            void EvaluateToonLight(
                Light li,
                half3 N,
                half3 V,
                half3 baseTint,
                half  isAdditional,
                out half3 diffuseOut,
                out half3 specOut,
                out half3 rimOut
            )
            {
                half3 L = normalize(li.direction);

                half ndl  = saturate(dot(N, L));
                half ramp = ToonRamp(ndl, (half)_Steps, (half)_RampSmooth);

                half sh = (half)li.shadowAttenuation;
                half shadowAmount = (1.0h - sh) * (half)_ShadowDarkness;

                half atten = (half)li.distanceAttenuation;
                half lightScale = lerp(1.0h, (half)_AdditionalIntensity, isAdditional);

                half3 litCol    = baseTint * ramp;
                half3 shadowCol = litCol * (half3)_ShadowTint.rgb;
                half3 diff      = lerp(litCol, shadowCol, shadowAmount);

                diffuseOut = diff * (half3)li.color * atten * lightScale;

                half3 H = normalize(L + V);
                half spRaw  = pow(saturate(dot(N, H)), (half)_SpecPower);
                half spBand = step((half)_SpecThreshold, spRaw);

                half specMul = lerp(1.0h, (half)_AdditionalSpecMul, isAdditional);
                specOut = spBand * (half3)_SpecColor.rgb * (half3)li.color * sh * atten * lightScale * specMul;

                half NoV = saturate(dot(N, V));
                half invNoV = saturate(1.0h - NoV);
                half rimRaw  = pow(invNoV, (half)_RimPower);
                half rimBand = step((half)_RimThreshold, rimRaw);

                half rimMul = lerp(1.0h, (half)_AdditionalRimMul, isAdditional);
                rimOut = rimBand * (half3)_RimColor.rgb * (half3)li.color * atten * lightScale * rimMul;
            }

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                VertexPositionInputs pos = GetVertexPositionInputs(IN.positionOS.xyz);
                VertexNormalInputs   nor = GetVertexNormalInputs(IN.normalOS);

                OUT.positionCS  = pos.positionCS;
                OUT.positionWS  = pos.positionWS;
                OUT.normalWS    = normalize(nor.normalWS);
                OUT.viewDirWS   = GetWorldSpaceViewDir(pos.positionWS);
                OUT.screenPos   = ComputeScreenPos(OUT.positionCS);
                OUT.shadowCoord = GetShadowCoord(pos);
                return OUT;
            }

            half4 frag(Varyings IN) : SV_Target
            {
                half3 N = normalize(IN.normalWS);
                half3 V = normalize(IN.viewDirWS);

                float2 screenUV = IN.screenPos.xy / max(IN.screenPos.w, 1e-5);

                half NoV = saturate(dot(N, V));
                half invNoV = saturate(1.0h - NoV);

                // 1) Refraction (keyword-gated)
                half3 refractedColor = _BaseColor.rgb;
                #if defined(_CRYSTAL_USE_SCENECOLOR)
                {
                    float2 refractOffset = (float2)N.xy * _RefractionStrength;

                    #if defined(_CRYSTAL_ABERRATION)
                        half r = SampleSceneColor(screenUV + refractOffset).r;
                        half g = SampleSceneColor(screenUV + refractOffset * (1.0 + _ChromaticAberration)).g;
                        half b = SampleSceneColor(screenUV + refractOffset * (1.0 + _ChromaticAberration * 2.0)).b;
                        refractedColor = half3(r, g, b);
                    #else
                        refractedColor = SampleSceneColor(screenUV + refractOffset);
                    #endif
                }
                #endif

                // 2) Facets (early out)
                half facet = 0;
                if (_FacetStrength > 1e-3)
                {
                    half facetNoise;
                    #if defined(_CRYSTAL_TRIPLANAR)
                        facetNoise = SampleFacetTriplanar((float3)IN.positionWS, (float3)N);
                    #else
                        float2 facetUV = (IN.positionWS.xz) * _FacetScale;
                        facetNoise = SAMPLE_TEXTURE2D(_FacetMap, sampler_FacetMap, facetUV).r;
                    #endif

                    facet = PowFast01(saturate(facetNoise), _FacetSharpness) * _FacetStrength;
                }

                // 3) Fresnel + Absorption
                half fresnel = pow(invNoV, _FresnelPower) * _FresnelStrength;

                half thicknessT = pow(invNoV, _ThicknessPower);
                half thickness  = lerp(_ThicknessMin, _ThicknessMax, thicknessT);

                half3 absorption    = _AbsorptionColor.rgb * _AbsorptionDensity;
                half3 transmittance = exp(-absorption * thickness);

                // 4) Lighting: main + additional
                half3 baseTint = (half3)_BaseColor.rgb;

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

                // 5) Light gate (smooth, no flicker)
                half lightE = LightEnergy01(surfaceLit);
                half lightGate = smoothstep(0.01h, 0.05h, lightE);

                refractedColor *= lightGate;

                // 6) Env reflection
                half3 R = reflect(-V, N);
                half perceptualRoughness = saturate(_Roughness);
                half3 envRefl = GlossyEnvironmentReflection(R, perceptualRoughness, 1.0h);
                envRefl *= (_ReflectionStrength * saturate(fresnel));
                envRefl *= lightGate;

                // 7) Internal facet sparkle (cheap)
                half3 approxLightColor = (half3)mainLight.color;
                #if defined(_ADDITIONAL_LIGHTS)
                    approxLightColor += 0.25h;
                #endif
                half3 internalFacet = facet * baseTint * approxLightColor;
                internalFacet *= lightGate;

                // 8) Composite
                half3 baseMix = lerp(refractedColor, surfaceLit, (half)_SurfaceWeight);
                half3 absorbed = baseMix * transmittance;
                

                half3 finalRGB = absorbed + envRefl + internalFacet;

                // True transparency
                half alphaOut = saturate((half)_Opacity);

                return half4(finalRGB, alphaOut);
            }
            ENDHLSL
        }

        UsePass "Universal Render Pipeline/Lit/ShadowCaster"
    }
}
