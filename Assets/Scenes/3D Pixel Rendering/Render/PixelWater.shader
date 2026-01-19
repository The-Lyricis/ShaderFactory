Shader "Pixel/Water_ToonPixel_URP"
{
    Properties
    {
        [Header(Base Color)]
        _ShallowColor("Shallow Color", Color) = (0.15, 0.55, 0.75, 1)
        _DeepColor("Deep Color", Color)       = (0.03, 0.12, 0.22, 1)
        _BaseAlpha("Base Alpha", Range(0,1))  = 0.55

        [Header(Pixel Quantization)]
        _PixelResolution("Pixel Resolution (W,H)", Vector) = (640, 360, 0, 0)

        [Header(Waves / Noise)]
        _NoiseTex("Noise Tex (Tileable)", 2D) = "gray" {}
        _NoiseScale("Noise Scale", Range(0.01, 10)) = 0.8
        _WaveSpeedA("Wave Speed A (xy)", Vector) = (0.08, 0.03, 0, 0)
        _WaveSpeedB("Wave Speed B (xy)", Vector) = (-0.05, 0.06, 0, 0)
        _WaveStrength("Wave Strength", Range(0, 2)) = 0.6

        [Header(Refraction)]
        _RefractionStrength("Refraction Strength", Range(0, 2)) = 0.35
        _RefractionDepthFade("Refraction Depth Fade", Range(0.01, 5)) = 1.5

        [Header(Edge Foam)]
        _FoamColor("Foam Color", Color) = (1,1,1,1)
        _FoamThreshold("Foam Threshold (EyeDepth)", Range(0.001, 2.0)) = 0.08
        _FoamNoiseAmount("Foam Noise Amount", Range(0, 1)) = 0.6
        _FoamStrength("Foam Strength", Range(0, 2)) = 1.0

        [Header(Caustics)]
        _CausticsTex("Caustics Tex", 2D) = "white" {}
        _CausticsScale("Caustics Scale", Range(0.01, 10)) = 1.2
        _CausticsSpeed("Caustics Speed", Range(0, 5)) = 0.6
        _CausticsStrength("Caustics Strength", Range(0, 2)) = 0.65
        _CausticsThreshold("Caustics Threshold", Range(0, 1)) = 0.55
        _CausticsSteps("Caustics Steps", Range(1, 6)) = 3

        [Header(Reflection)]
        [Toggle(_USE_PLANAR_REFLECTION)] _UsePlanarReflection("Use Planar Reflection", Float) = 0
        _PlanarReflectionTex("Planar Reflection Tex", 2D) = "black" {}
        _ReflectionStrength("Reflection Strength", Range(0, 1)) = 0.35
        _FresnelPower("Fresnel Power", Range(0.5, 8)) = 3.0

        [Header(Toon Banding)]
        _LightingSteps("Lighting Steps", Range(1, 6)) = 3
        _LightingSmooth("Lighting Smooth", Range(0, 0.4)) = 0.06
        _SpecSparkle("Spec Sparkle Strength", Range(0, 1)) = 0.18
        _SpecPower("Spec Power", Range(1, 128)) = 48
    }

    SubShader
    {
        Tags { "RenderPipeline"="UniversalPipeline" "Queue"="Transparent" "RenderType"="Transparent" }

        Pass
        {
            Name "WaterForward"
            Tags { "LightMode"="UniversalForward" }

            Blend SrcAlpha OneMinusSrcAlpha
            ZWrite Off
            Cull Back

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #pragma multi_compile_instancing
            #pragma multi_compile_fog
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE
            #pragma multi_compile _ _SHADOWS_SOFT
            #pragma shader_feature _USE_PLANAR_REFLECTION

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareOpaqueTexture.hlsl"

            TEXTURE2D(_NoiseTex);           SAMPLER(sampler_NoiseTex);
            TEXTURE2D(_CausticsTex);        SAMPLER(sampler_CausticsTex);
            TEXTURE2D(_PlanarReflectionTex); SAMPLER(sampler_PlanarReflectionTex);
            
            SAMPLER(sampler_PointClamp);
            SAMPLER(sampler_LinearClamp);

            CBUFFER_START(UnityPerMaterial)
                half4 _ShallowColor;
                half4 _DeepColor;
                half  _BaseAlpha;
                float4 _PixelResolution;
                half  _NoiseScale;
                float4 _WaveSpeedA;
                float4 _WaveSpeedB;
                half  _WaveStrength;
                half  _RefractionStrength;
                half  _RefractionDepthFade;
                half4 _FoamColor;
                half  _FoamThreshold;
                half  _FoamNoiseAmount;
                half  _FoamStrength;
                half  _CausticsScale;
                half  _CausticsSpeed;
                half  _CausticsStrength;
                half  _CausticsThreshold;
                half  _CausticsSteps;
                half  _ReflectionStrength;
                half  _FresnelPower;
                half  _LightingSteps;
                half  _LightingSmooth;
                half  _SpecSparkle;
                half  _SpecPower;
            CBUFFER_END

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
                float2 uv         : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float3 positionWS : TEXCOORD0;
                half3  normalWS   : TEXCOORD1;
                float2 uv         : TEXCOORD2;
                float4 screenPos  : TEXCOORD3;
                half   fogFactor  : TEXCOORD4;
                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };

            float2 QuantizeScreenUV(float2 uv)
            {
                float2 pr = max(_PixelResolution.xy, float2(1, 1));
                return floor(uv * pr + 0.5) / pr;
            }

            half ToonRamp(half x01, half steps, half smooth)
            {
                half s = max(steps, 1.0h);
                half x = x01 * s;
                half q0 = floor(x) / s;
                if (smooth <= 0.0h) return q0;
                half q1 = (floor(x) + 1.0h) / s;
                half t  = frac(x);
                half k  = smoothstep(0.5h - smooth, 0.5h + smooth, t);
                return lerp(q0, q1, k);
            }

            float Hash21(float2 p)
            {
                p = frac(p * float2(123.34, 456.21));
                p += dot(p, p + 34.345);
                return frac(p.x * p.y);
            }

            float Noise2(float2 xz, float2 speed)
            {
                float2 uv = xz * _NoiseScale + speed * _Time.y;
                return SAMPLE_TEXTURE2D(_NoiseTex, sampler_NoiseTex, uv).r;
            }

            half3 WaveNormalWS(float3 posWS)
            {
                float2 xz = posWS.xz;
                float n = (Noise2(xz, _WaveSpeedA.xy) + Noise2(xz, _WaveSpeedB.xy)) * 0.5;
                float eps = 0.05;
                float nX = (Noise2(xz + float2(eps, 0), _WaveSpeedA.xy) + Noise2(xz + float2(eps, 0), _WaveSpeedB.xy)) * 0.5;
                float nZ = (Noise2(xz + float2(0, eps), _WaveSpeedA.xy) + Noise2(xz + float2(0, eps), _WaveSpeedB.xy)) * 0.5;
                float2 grad = float2(nX - n, nZ - n) * _WaveStrength;
                return normalize(half3(-grad.x, 1.0, -grad.y));
            }

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                UNITY_SETUP_INSTANCE_ID(IN);
                UNITY_TRANSFER_INSTANCE_ID(IN, OUT);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(OUT);

                VertexPositionInputs pos = GetVertexPositionInputs(IN.positionOS.xyz);
                VertexNormalInputs nor = GetVertexNormalInputs(IN.normalOS);

                OUT.positionCS = pos.positionCS;
                OUT.positionWS = pos.positionWS;
                OUT.normalWS   = (half3)nor.normalWS;
                OUT.uv         = IN.uv;
                OUT.screenPos  = ComputeScreenPos(OUT.positionCS);
                OUT.fogFactor  = ComputeFogFactor(OUT.positionCS.z);
                return OUT;
            }

            half4 frag(Varyings IN) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(IN);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(IN);

                float2 screenUV = IN.screenPos.xy / max(1e-5, IN.screenPos.w);
                float2 qUV = QuantizeScreenUV(screenUV);

                // --- Depth ---
                // 使用 URP 内置宏安全采样
                float rawSceneDepth = SampleSceneDepth(qUV);
                float sceneEye = LinearEyeDepth(rawSceneDepth, _ZBufferParams);
                float waterEye = IN.screenPos.w; // 正交/透视通用的深度获取方式
                float depthDiff = max(sceneEye - waterEye, 0.0);
                float depth01 = saturate(depthDiff / max(1e-3, _RefractionDepthFade));

                // --- Waves ---
                half3 waveN = WaveNormalWS(IN.positionWS);
                half3 N = normalize(lerp(IN.normalWS, waveN, 0.85h));

                // --- Refraction ---
                float2 refrOffset = (float2(N.x, N.z)) * _RefractionStrength;
                float2 pr = max(_PixelResolution.xy, float2(1, 1));
                float2 refrOffsetUV = floor(refrOffset * pr + 0.5) / pr;
                float2 refrUV = QuantizeScreenUV(screenUV + refrOffsetUV);
                
                // 使用 URP 内置宏安全采样 Opaque
                float3 refrCol = SampleSceneColor(refrUV);

                // --- Colors ---
                float3 waterCol = lerp(_ShallowColor.rgb, _DeepColor.rgb, depth01);
                float refrMix = saturate(depth01 * 0.9);
                float3 baseCol = lerp(waterCol, refrCol * waterCol, refrMix);

                // --- Foam ---
                float foamNoise = Noise2(IN.positionWS.xz, float2(0.12, -0.09));
                foamNoise = lerp(1.0, foamNoise, _FoamNoiseAmount);
                float foamMask = 1.0 - smoothstep(0.0, _FoamThreshold * foamNoise, depthDiff);
                foamMask = saturate(foamMask * _FoamStrength);

                // --- Caustics ---
                float2 cUV1 = IN.positionWS.xz * _CausticsScale + _Time.y * _CausticsSpeed;
                float2 cUV2 = IN.positionWS.xz * (_CausticsScale * 1.31) - _Time.y * (_CausticsSpeed * 0.73);
                float caust = min(SAMPLE_TEXTURE2D(_CausticsTex, sampler_CausticsTex, cUV1).r, 
                                 SAMPLE_TEXTURE2D(_CausticsTex, sampler_CausticsTex, cUV2).r);
                caust = saturate((caust - _CausticsThreshold) / max(1e-4, (1.0 - _CausticsThreshold)));
                caust = ToonRamp(caust, _CausticsSteps, 0.0h) * (1.0 - depth01) * _CausticsStrength;

                // --- Lighting ---
                Light mainLight = GetMainLight(TransformWorldToShadowCoord(IN.positionWS));
                half3 L = normalize((half3)mainLight.direction);
                half ndl = saturate(dot(N, L) * 0.5h + 0.5h);
                half litBand = ToonRamp(ndl, _LightingSteps, _LightingSmooth);
                float3 litCol = baseCol * litBand * mainLight.color.rgb;

                // --- Sparkle ---
                half3 V = normalize((half3)GetWorldSpaceViewDir(IN.positionWS));
                half3 H = normalize(L + V);
                half specRaw = pow(saturate(dot(N, H)), _SpecPower);
                float rnd = Hash21(floor(screenUV * pr));
                half sparkle = _SpecSparkle * step(0.78, rnd) * step(0.5, specRaw);
                litCol += sparkle * mainLight.color.rgb;

                // --- Reflection ---
                #if defined(_USE_PLANAR_REFLECTION)
                    float fres = pow(1.0 - saturate(dot(N, V)), _FresnelPower);
                    float3 refl = SAMPLE_TEXTURE2D(_PlanarReflectionTex, sampler_LinearClamp, qUV).rgb;
                    litCol = lerp(litCol, refl, fres * _ReflectionStrength);
                #endif

                float3 colOut = litCol + caust;
                colOut = lerp(colOut, _FoamColor.rgb, foamMask);

                float alpha = lerp(_BaseAlpha * 0.65, _BaseAlpha, depth01);
                alpha = saturate(alpha + foamMask * 0.35);

                colOut = MixFog(colOut, IN.fogFactor);
                return half4(colOut, alpha);
            }
            ENDHLSL
        }
    }
}