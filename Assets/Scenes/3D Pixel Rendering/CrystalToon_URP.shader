Shader "Pixel/CrystalToon_URP"
{
    Properties
    {
        [Header(Base Appearance)]
        _BaseMap("Base Texture (Internal Detail)", 2D) = "white" {}
        _BaseColor("Crystal Color", Color) = (1,1,1,1)
        _Opacity("Opacity (Refraction Mix)", Range(0, 1)) = 0.5

        [Header(Refraction)]
        _RefractionStrength("Refraction Strength", Range(0, 0.2)) = 0.05
        _ChromaticAberration("Chromatic Aberration", Range(0, 0.05)) = 0.01

        [Header(Internal Facets)]
        _FacetMap("Facet Texture (Noise)", 2D) = "white" {}
        _FacetScale("Facet Scale", Range(0.1, 10)) = 2.0
        _FacetStrength("Facet Strength", Range(0, 2)) = 1.0

        [Header(Toon Lighting)]
        _Steps("Toon Steps", Range(1,5)) = 3
        _RampSmooth("Step Smoothness", Range(0,1)) = 0.05
        _ShadowTint("Shadow Tint", Color) = (0.5, 0.5, 0.6, 1)
        _ShadowDarkness("Shadow Darkness", Range(0,1)) = 0.5

        [Header(Specular and Rim)]
        _SpecColor("Specular Color", Color) = (1,1,1,1)
        _SpecPower("Specular Power", Range(1,128)) = 64
        _SpecThreshold("Spec Threshold", Range(0,1)) = 0.6
        _RimColor("Rim Color", Color) = (1,1,1,1)
        _RimPower("Rim Power", Range(0.5,8)) = 4
    }

    SubShader
    {
        Tags
        {
            "RenderPipeline"="UniversalPipeline"
            "Queue"="Transparent"
            "RenderType"="Transparent"
        }

        Pass
        {
            Name "ForwardLit"
            Tags { "LightMode"="UniversalForward" }
            
            // 水晶通常需要写入深度以防止前后乱序，虽然是透明队列
            ZWrite On
            Blend SrcAlpha OneMinusSrcAlpha

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_fog
            
            // 必须包含阴影变体
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE
            #pragma multi_compile_fragment _ _ADDITIONAL_LIGHTS
            #pragma multi_compile_fragment _ _SHADOWS_SOFT

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareOpaqueTexture.hlsl"

            TEXTURE2D(_BaseMap); SAMPLER(sampler_BaseMap);
            TEXTURE2D(_FacetMap); SAMPLER(sampler_FacetMap);

            CBUFFER_START(UnityPerMaterial)
                float4 _BaseMap_ST;
                float4 _BaseColor;
                float _Opacity;
                float _RefractionStrength;
                float _ChromaticAberration;
                float _FacetScale;
                float _FacetStrength;
                float _Steps;
                float _RampSmooth;
                float4 _ShadowTint;
                float _ShadowDarkness;
                float4 _SpecColor;
                float _SpecPower;
                float _SpecThreshold;
                float4 _RimColor;
                float _RimPower;
            CBUFFER_END

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
                float2 uv         : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionCS   : SV_POSITION;
                float2 uv           : TEXCOORD0;
                float4 screenPos    : TEXCOORD1;
                float3 normalWS     : TEXCOORD3;
                float3 viewDirWS    : TEXCOORD4;
                float3 positionWS   : TEXCOORD5;
                float4 shadowCoord  : TEXCOORD6; // 修正：直接手动声明
            };

            half ToonRamp(half x, half steps, half smooth)
            {
                half s = max(steps, 1.0h);
                half x_s = x * s;
                half q0 = floor(x_s) / s;
                half q1 = ceil(x_s) / s;
                return lerp(q0, q1, smoothstep(0.5h - smooth, 0.5h + smooth, frac(x_s)));
            }

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                VertexPositionInputs posInputs = GetVertexPositionInputs(IN.positionOS.xyz);
                VertexNormalInputs norInputs = GetVertexNormalInputs(IN.normalOS);

                OUT.positionCS = posInputs.positionCS;
                OUT.positionWS = posInputs.positionWS;
                OUT.uv = TRANSFORM_TEX(IN.uv, _BaseMap);
                OUT.normalWS = normalize(norInputs.normalWS);
                OUT.viewDirWS = GetWorldSpaceViewDir(posInputs.positionWS);
                OUT.screenPos = ComputeScreenPos(OUT.positionCS);
                
                // 修正：使用更通用的获取阴影坐标的方法
                #if UNITY_ANY_INSTANCING_ENABLED
                    OUT.shadowCoord = TransformWorldToShadowCoord(posInputs.positionWS);
                #else
                    OUT.shadowCoord = GetShadowCoord(posInputs);
                #endif
                
                return OUT;
            }

            half4 frag(Varyings IN) : SV_Target
            {
                float3 N = normalize(IN.normalWS);
                float3 V = normalize(IN.viewDirWS);
                
                // 1. 折射 (Refraction)
                float2 screenUV = IN.screenPos.xy / IN.screenPos.w;
                float2 refractOffset = N.xy * _RefractionStrength;
                
                half backgroundR = SampleSceneColor(screenUV + refractOffset).r;
                half backgroundG = SampleSceneColor(screenUV + refractOffset * (1.0 + _ChromaticAberration)).g;
                half backgroundB = SampleSceneColor(screenUV + refractOffset * (1.0 + _ChromaticAberration * 2.0)).b;
                half3 refractedColor = half3(backgroundR, backgroundG, backgroundB);

                // 2. 内部刻面 (Internal Facets)
                float2 facetUV = (IN.positionWS.xz + N.xy) * _FacetScale;
                half facet = SAMPLE_TEXTURE2D(_FacetMap, sampler_FacetMap, facetUV).r;
                facet = pow(facet, 3.0) * _FacetStrength;

                // 3. 主灯光
                // 修正：显式传入阴影坐标
                Light light = GetMainLight(IN.shadowCoord);
                half3 L = normalize(light.direction);
                half d = saturate(dot(N, L));
                half ramp = ToonRamp(d, _Steps, _RampSmooth);
                
                half shadow = light.shadowAttenuation;
                half3 litColor = _BaseColor.rgb * ramp;
                half3 shadowColor = litColor * _ShadowTint.rgb;
                
                // 结合 Toon 步进和阴影衰减
                half3 diffuse = lerp(shadowColor, litColor, shadow);

                // 4. 高光 (Banded Specular)
                half3 H = normalize(L + V);
                half specRaw = pow(saturate(dot(N, H)), _SpecPower);
                half spec = step(_SpecThreshold, specRaw);
                half3 specular = spec * _SpecColor.rgb * shadow * light.color;

                // 5. 边缘光 (Crystal Rim)
                half rim = pow(1.0 - saturate(dot(N, V)), _RimPower);
                half3 rimColor = step(0.5, rim) * _RimColor.rgb * light.color;

                // 最终合成
                half3 finalColor = lerp(refractedColor, diffuse, _Opacity);
                finalColor += facet * _BaseColor.rgb * light.color; // 内部反光随主光变色
                finalColor += specular + rimColor;

                return half4(finalColor, 1.0);
            }
            ENDHLSL
        }
        
        // 阴影投射 Pass（必须有，否则水晶不会投射阴影）
        UsePass "Universal Render Pipeline/Lit/ShadowCaster"
    }
}