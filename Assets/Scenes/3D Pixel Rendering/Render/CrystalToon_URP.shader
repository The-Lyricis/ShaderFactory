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

            CBUFFER_START(UnityPerMaterial)
                float _DepthPrepass;
            CBUFFER_END

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

            // 只画背面（内部面）
            Cull Front

            // 关键：不写深度，避免封死自身后层
            ZWrite Off

            // 关键：使用当前 LowResDepth（此时应当还是 OpaqueDepth），保证不穿墙
            ZTest LEqual

            Blend SrcAlpha OneMinusSrcAlpha

            HLSLPROGRAM
            #pragma vertex vertBack
            #pragma fragment fragBack

            // 阴影 / 追加灯变体（如你不需要可裁剪）
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE
            #pragma multi_compile_fragment _ _SHADOWS_SOFT
            #pragma multi_compile_fragment _ _ADDITIONAL_LIGHTS
            #pragma multi_compile_fragment _ _ADDITIONAL_LIGHT_SHADOWS

            // 与主 Pass 保持一致的功能开关（如果你有）
            #pragma shader_feature_local _CRYSTAL_TRIPLANAR

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            // 说明：
            // - 不 include DeclareOpaqueTexture，也不 SampleSceneColor（避免把背景折射重复叠加）
            // - 该 Pass 只做“内部贡献”，用于显示背面棱角/内部层次

            // ---------- 与主 Pass 一致的结构 ----------
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

            // ---------- 复用你原来 ToonRamp（若已在别处定义，可删除此处以避免重复） ----------
            half ToonRamp(half x, half steps, half smooth)
            {
                half s = max(steps, 1.0h);
                half xs = x * s;
                half q0 = floor(xs) / s;
                half q1 = ceil(xs)  / s;
                half t  = smoothstep(0.5h - smooth, 0.5h + smooth, frac(xs));
                return lerp(q0, q1, t);
            }

            // ---------- Triplanar 采样（内部噪声更稳，不随 UV 滑动） ----------
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

            Varyings vertBack(Attributes IN)
            {
                Varyings OUT;

                VertexPositionInputs pos = GetVertexPositionInputs(IN.positionOS.xyz);
                VertexNormalInputs   nor = GetVertexNormalInputs(IN.normalOS);

                OUT.positionCS = pos.positionCS;
                OUT.positionWS = pos.positionWS;
                OUT.normalWS   = normalize(nor.normalWS);
                OUT.viewDirWS  = GetWorldSpaceViewDir(pos.positionWS);

                // 让内部面也能受主光阴影影响（可选）
                OUT.shadowCoord = GetShadowCoord(pos);

                return OUT;
            }

            half4 fragBack(Varyings IN) : SV_Target
            {
                half3 V = normalize(IN.viewDirWS);

                // 关键：这是背面 Pass，但顶点法线仍然是“外法线”
                // 为了把背面当作“朝向相机的内部表面”来做光照，需要翻转法线
                half3 N = -normalize(IN.normalWS);

                half NoV = saturate(dot(N, V));

                // ---------- 厚度近似（掠射更厚） ----------
                half thicknessT = pow(1.0h - NoV, _ThicknessPower);
                half thickness  = lerp(_ThicknessMin, _ThicknessMax, thicknessT);

                // ---------- Beer-Lambert 吸收（内部更深） ----------
                half3 absorption    = _AbsorptionColor.rgb * _AbsorptionDensity;
                half3 transmittance = exp(-absorption * thickness);

                // ---------- 内部刻面 ----------
                half facetNoise;
                #if defined(_CRYSTAL_TRIPLANAR)
                    facetNoise = SampleFacetTriplanar((float3)IN.positionWS, (float3)N);
                #else
                    float2 facetUV = IN.positionWS.xz * _FacetScale;
                    facetNoise = SAMPLE_TEXTURE2D(_FacetMap, sampler_FacetMap, facetUV).r;
                #endif

                half facet = pow(saturate(facetNoise), _FacetSharpness) * _FacetStrength;

                // ---------- 主光（内部漫反射 + 受阴影） ----------
                Light mainLight = GetMainLight(IN.shadowCoord);
                half3 L = normalize(mainLight.direction);

                half ndl   = saturate(dot(N, L));
                half ramp  = ToonRamp(ndl, _Steps, _RampSmooth);
                half shadowAtten = mainLight.shadowAttenuation;

                // 内部漫反射：偏“晶体内部发亮”，不使用 _ShadowTint（避免内部过脏）
                half3 diffuse = _BaseColor.rgb * ramp * mainLight.color * shadowAtten;

                // ---------- 内部高光（阈值高光更像“棱角闪”） ----------
                half3 H = normalize(L + V);
                half specRaw = pow(saturate(dot(N, H)), _SpecPower);
                half spec    = step(_SpecThreshold, specRaw);
                half3 specular = spec * _SpecColor.rgb * mainLight.color * shadowAtten;

                // ---------- 内部边缘光（让背面轮廓更“见得着”） ----------
                half rimRaw = pow(1.0h - NoV, _RimPower);
                half rim    = step(_RimThreshold, rimRaw);
                half3 rimCol = rim * _RimColor.rgb * mainLight.color;

                // ---------- 合成：内部颜色 = 吸收后的漫反射 + 刻面闪 + 高光 + rim ----------
                // transmittance 让内部越厚越暗（更像晶体）
                half3 internalCol = diffuse * transmittance;

                // facet 作为“内部碎晶闪烁”，不完全受 transmittance（保留一定亮点）
                internalCol += facet * _BaseColor.rgb * (0.35h + 0.65h * shadowAtten) * mainLight.color;

                internalCol += (specular + rimCol) * (0.5h + 0.5h * facet);

                // ---------- alpha：内部贡献应当随透明度增强 ----------
                // _Opacity 越低（越透明），内部越明显
                half alpha = saturate((1.0h - _Opacity) * 0.85h);
                // 掠射角加强一点内部存在感
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

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareOpaqueTexture.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/ImageBasedLighting.hlsl"

            TEXTURE2D(_BaseMap);  SAMPLER(sampler_BaseMap);
            TEXTURE2D(_FacetMap); SAMPLER(sampler_FacetMap);

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

            // 量化 Toon Ramp（0..1）
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

            // Triplanar facet
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

            // -------- 核心：统一多光源 Toon 评估 --------
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

                // Shadow blend (稳定、可控)
                // shadowAttenuation: 1=亮, 0=阴影
                half sh = (half)li.shadowAttenuation;
                half shadowAmount = (1.0h - sh) * (half)_ShadowDarkness;  // 0..ShadowDarkness

                // 点光/聚光衰减（range 会通过 distanceAttenuation 体现）
                half atten = (half)li.distanceAttenuation;
                // 主光距离衰减一般为1，这里统一写
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

                // Rim (banded) —— rim 与光方向无关，但保留 light color/atten 让多灯有色影响
                half NoV = saturate(dot(N, V));
                half rimRaw  = pow(1.0h - NoV, (half)_RimPower);
                half rimBand = step((half)_RimThreshold, rimRaw);

                half rimMul = lerp(1.0h, (half)_AdditionalRimMul, isAdditional);
                rimOut = rimBand * (half3)_RimColor.rgb * (half3)li.color * atten * lightScale * rimMul;
            }
            half LightEnergy01(half3 c)
            {
                // 简单亮度估计
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
                // 4) Lighting: main + additional (统一评估)
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
                // 可选：让它更“硬”
                lightE = step(0.02h, lightE);  
                refractedColor *= lightE;     // 无灯 perceived black（不再透出背景）
                // -----------------------------
                // 5) Env reflection (IBL)
                // -----------------------------
                half3 R = reflect(-V, N);
                half perceptualRoughness = saturate(_Roughness);
                half3 envRefl = GlossyEnvironmentReflection(R, perceptualRoughness, 1.0h);
                envRefl *= (_ReflectionStrength * saturate(fresnel));
                envRefl        *= lightE;     // 无灯不反射
                // -----------------------------
                // 6) Internal facet sparkle (轻量)
                // -----------------------------
                // 用所有灯的亮度粗略驱动（避免只吃主光）
                half3 approxLightColor = (half3)mainLight.color;
                #if defined(_ADDITIONAL_LIGHTS)
                    approxLightColor += 0.25h; // 轻补偿：避免 0 灯时太暗
                #endif
                half3 internalFacet = facet * baseTint * approxLightColor;
                internalFacet  *= lightE;     // 无灯不闪
                // -----------------------------
                // 7) Composite
                // -----------------------------
                // 表面/折射混合（_Opacity 仍作为“表面占比”）
                half3 baseMix = lerp(refractedColor, surfaceLit, (half)_Opacity);

                // 吸收（近似）
                half3 absorbed = baseMix * transmittance;

                // 反射叠加 + facet
                half3 finalRGB = absorbed + envRefl + internalFacet;

                // 透明输出：若你希望真正透明，请让 alpha 跟 _Opacity 绑定
                // 若你坚持“视觉透明但 alpha=1”，把下面改回 1
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
