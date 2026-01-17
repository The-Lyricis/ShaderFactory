Shader "Pixel/ToonLit_Complete_URP"
{
    Properties
    {
        [Header(Base Appearance)]
        _BaseMap("Base Texture", 2D) = "white" {}
        _BaseColor("Base Color", Color) = (1,1,1,1)

        [Header(Toon Lighting)]
        _Steps("Toon Steps", Range(1,5)) = 3
        _RampSmooth("Step Smoothness", Range(0,1)) = 0.05
        _ShadowTint("Shadow Tint Color", Color) = (0.5, 0.5, 0.6, 1)

        [Header(Specular and Rim)]
        _SpecColor("Specular Color", Color) = (1,1,1,1) 
        _SpecPower("Specular Power", Range(1,128)) = 32
        _SpecStrength("Specular Strength", Range(0,1)) = 0.2
        _RimColor("Rim Light Color", Color) = (1,1,1,1)
        _RimPower("Rim Exponent", Range(0.5,8)) = 2
        _RimStrength("Rim Strength", Range(0,1)) = 0.25
    }

    SubShader
    {
        Tags
        {
            "RenderPipeline"="UniversalPipeline"
            "Queue"="Geometry"
            "RenderType"="Opaque"
        }

        // --- PASS 1: Main Shading Pass ---
        Pass
        {
            Name "ForwardLit"
            Tags { "LightMode"="UniversalForward" }

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            
            // URP Keywords for Shadows and Lights
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE
            #pragma multi_compile _ _SHADOWS_SOFT
            #pragma multi_compile_fragment _ _ADDITIONAL_LIGHTS

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            TEXTURE2D(_BaseMap); SAMPLER(sampler_BaseMap);

            CBUFFER_START(UnityPerMaterial)
                float4 _BaseMap_ST;
                float4 _BaseColor;
                float _Steps;
                float _RampSmooth;
                float4 _ShadowTint;
                float4 _SpecColor;
                float _SpecPower;
                float _SpecStrength;
                float4 _RimColor;
                float _RimPower;
                float _RimStrength;
            CBUFFER_END

            struct Attributes {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
                float2 uv         : TEXCOORD0;
            };

            struct Varyings {
                float4 positionCS : SV_POSITION;
                float2 uv         : TEXCOORD0;
                float3 positionWS : TEXCOORD1;
                float3 normalWS   : TEXCOORD2;
                float4 shadowCoord : TEXCOORD3;
                float3 viewDirWS   : TEXCOORD4;
            };

            // Quantize light intensity into discrete steps
            float ToonRamp(float ndl, float steps, float smooth) {
                float x = ndl * steps;
                float baseStep = floor(x) / steps;
                float nextStep = (floor(x) + 1.0) / steps;
                float t = frac(x);
                float s = smoothstep(0.5 - smooth, 0.5 + smooth, t);
                return lerp(baseStep, nextStep, s);
            }

            Varyings vert(Attributes IN) {
                Varyings OUT;
                VertexPositionInputs posInputs = GetVertexPositionInputs(IN.positionOS.xyz);
                VertexNormalInputs norInputs = GetVertexNormalInputs(IN.normalOS);
                
                OUT.positionCS = posInputs.positionCS;
                OUT.positionWS = posInputs.positionWS;
                OUT.normalWS = normalize(norInputs.normalWS);
                OUT.uv = TRANSFORM_TEX(IN.uv, _BaseMap);
                OUT.viewDirWS = GetWorldSpaceViewDir(OUT.positionWS);
                OUT.shadowCoord = GetShadowCoord(posInputs);
                return OUT;
            }

            half4 frag(Varyings IN) : SV_Target {
                // Fetch Texture and Base Color
                float3 albedo = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, IN.uv).rgb * _BaseColor.rgb;
                float3 N = normalize(IN.normalWS);
                float3 V = normalize(IN.viewDirWS);
                
                // Main Light Calculation
                Light mainLight = GetMainLight(IN.shadowCoord);
                float3 L = normalize(mainLight.direction);
                
                // Half-Lambert adjustment for softer, more painterly shadows
                float ndl = saturate(dot(N, L) * 0.5 + 0.5);
                float ramp = ToonRamp(ndl, _Steps, _RampSmooth);
                
                float shadowAtten = step(0.3, mainLight.shadowAttenuation);
                float3 lit = albedo * ramp * mainLight.color;

                // Shadow Tinting: Blends dark areas towards a specific color instead of black
                float shadowFactor = 1.0 - (ramp * shadowAtten);
                lit = lerp(lit, albedo * _ShadowTint.rgb, shadowFactor);

                // Toon Specular (Hard-edged highlight)
                float3 H = normalize(L + V);
                float spec = pow(saturate(dot(N, H)), _SpecPower);
                lit += _SpecColor.rgb * step(0.5, spec) * _SpecStrength * shadowAtten;

                // Rim Lighting for silhouette definition
                float rim = pow(1.0 - saturate(dot(N, V)), _RimPower);
                lit += _RimColor.rgb * rim * _RimStrength;
              
                return half4(lit, 1.0);
            }
            ENDHLSL
        }

        // --- PASS 2: DepthNormals Pass ---
        // Crucial for Post-Processing Outlines to detect edges
        Pass
        {
            Name "DepthNormals"
            Tags { "LightMode" = "DepthNormals" }

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            struct Attributes {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
            };

            struct Varyings {
                float4 positionCS : SV_POSITION;
                float3 normalWS   : TEXCOORD0;
            };

            Varyings vert(Attributes IN) {
                Varyings OUT;
                OUT.positionCS = TransformObjectToHClip(IN.positionOS.xyz);
                OUT.normalWS = TransformObjectToWorldNormal(IN.normalOS);
                return OUT;
            }

            float4 frag(Varyings IN) : SV_Target {
                // Encode normals into [0, 1] range for the buffer
                return float4(normalize(IN.normalWS) * 0.5 + 0.5, 0.0);
            }
            ENDHLSL
        }

        // Standard Shadow Caster Pass
        UsePass "Universal Render Pipeline/Lit/ShadowCaster"
    }
}