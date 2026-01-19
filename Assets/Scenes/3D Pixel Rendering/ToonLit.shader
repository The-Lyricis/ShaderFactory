Shader "Pixel/ToonLit_URP"
{
    Properties
    {
        [Header(Base Appearance)]
        _BaseMap("Base Texture", 2D) = "white" {}
        _BaseColor("Base Color", Color) = (1,1,1,1)

        [Header(Toon Lighting)]
        _Steps("Toon Steps", Range(1,5)) = 3
        _RampSmooth("Step Smoothness", Range(0,1)) = 0.05
        [Header(Additional Light Range Bands)]
        _RangeSteps("Range Steps (Rings)", Range(1, 16)) = 6
        _RangeContrast("Range Contrast", Range(0.5, 6)) = 2.5


        // Shadow tint and intensity control
        _ShadowTint("Shadow Tint Color", Color) = (0.5, 0.5, 0.6, 1)
        _ShadowDarkness("Shadow Darkness", Range(0,1)) = 0.65

        // Godot-inspired controls:
        // Wrap lifts the dark side (backlight), Steepness increases contrast / hardness
        _Wrap("Wrap (Backlight Lift)", Range(-1, 1)) = 0.0
        _Steepness("Steepness", Range(0.5, 8)) = 1.0

        // Shadow edge shaping (AA hard edge)
        _ShadowHardness("Shadow Hardness", Range(0.5, 8)) = 2.0

        [Header(Specular and Rim)]
        _SpecColor("Specular Color", Color) = (1,1,1,1)
        _SpecPower("Specular Power", Range(1,128)) = 32
        _SpecStrength("Specular Strength", Range(0,1)) = 0.2

        _SpecThreshold("Specular Threshold", Range(0,1)) = 0.5
        _SpecSoftness("Specular Softness", Range(0,0.5)) = 0.08

        _RimColor("Rim Light Color", Color) = (1,1,1,1)
        _RimPower("Rim Exponent", Range(0.5,8)) = 2
        _RimStrength("Rim Strength", Range(0,1)) = 0.25

        _RimThreshold("Rim Threshold", Range(0,1)) = 0.3
        _RimSoftness("Rim Softness", Range(0,0.5)) = 0.12
    }

    SubShader
    {
        Tags
        {
            "RenderPipeline"="UniversalPipeline"
            "Queue"="Geometry"
            "RenderType"="Opaque"
        }

        // ============================================================
        // PASS 1: Main Shading Pass
        // ============================================================
        Pass
        {
            Name "ForwardLit"
            Tags { "LightMode"="UniversalForward" }

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #pragma multi_compile_instancing
            #pragma multi_compile_fog

            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE
            #pragma multi_compile _ _SHADOWS_SOFT
            #pragma multi_compile_fragment _ _ADDITIONAL_LIGHTS
            #pragma multi_compile_fragment _ _ADDITIONAL_LIGHT_SHADOWS

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/RealtimeLights.hlsl"


            TEXTURE2D(_BaseMap); SAMPLER(sampler_BaseMap);

            CBUFFER_START(UnityPerMaterial)
                float4 _BaseMap_ST;
                float4 _BaseColor;

                float  _Steps;
                float  _RampSmooth;
                float4 _ShadowTint;
                float  _ShadowHardness;
                float  _ShadowDarkness;

                float  _Wrap;
                float  _Steepness;

                float4 _SpecColor;
                float  _SpecPower;
                float  _SpecStrength;
                float  _SpecThreshold;
                float  _SpecSoftness;

                float4 _RimColor;
                float  _RimPower;
                float  _RimStrength;
                float  _RimThreshold;
                float  _RimSoftness;
                float _RangeSteps;
                float _RangeContrast;
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
                float4 positionCS   : SV_POSITION;
                float2 uv           : TEXCOORD0;
                float3 positionWS   : TEXCOORD1;
                half3  normalWS     : TEXCOORD2;
                float4 shadowCoord  : TEXCOORD3;
                half   fogFactor    : TEXCOORD4;

                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };

            // Quantize x in [0,1] into toon steps with optional smoothing.
            half ToonRamp(half x01, half steps, half smooth)
            {
                half s = max(steps, 1.0h);

                // Base quantized step
                half x = x01 * s;
                half q0 = floor(x) / s;

                // Optional soft transition between steps (AA-friendly)
                if (smooth <= 0.0h) return q0;

                half q1 = (floor(x) + 1.0h) / s;
                half t  = frac(x);

                // Smooth around the midpoint of each step interval
                half k = smoothstep(0.5h - smooth, 0.5h + smooth, t);
                return lerp(q0, q1, k);
            }
            // Hard ring quantization that is inclusive inside range.
            // radius01: 1 at center, 0 at range boundary
           half RangeRampHardInclusive(half radius01, half steps, half contrast)
            {
                half s = max(steps, 1.0h);
                
                // 映射 radius01 (1->0) 
                // 使用 floor 让阶梯向外扩散，+1.0/s 确保中心最亮
                // 或者简单的：
                half q = floor(saturate(radius01) * s) / (s - 1.0h); 
                
                // 如果你希望最外圈是可见的，且刚好消失在 range 边界：
                // 我们使用饱和度调整，确保 0 处确实是 0
                q = saturate(q);

                // 对比度增强
                q = pow(q, max(contrast, 0.001h));
                return q;
            }
    

            // Hard-ish shadow edge with AA using fwidth.
            // Returns: 0=in shadow, 1=in light
            half StylizedShadow(half shadowAtten01)
            {
                half shadowThreshold = 0.5h;
                half aaRange = fwidth(shadowAtten01); // ~1 pixel wide transition
                return smoothstep(shadowThreshold - aaRange, shadowThreshold + aaRange, shadowAtten01);
            }

            // Stable band helper for spec/rim (soft step).
            half Band(half x, half threshold, half softness)
            {
                half a = threshold - softness;
                half b = threshold + softness;
                return smoothstep(a, b, x);
            }

            // Godot-inspired diffuse driver:
            // - use half-lambert baseline, then wrap & steepness for artistic control
            half DiffuseDriver01(half3 N, half3 L)
            {
                // Half-lambert baseline (stable for toon & low-res)
                half ndl = dot(N, L);          // -1..1
                ndl = ndl * 0.5h + 0.5h;       // 0..1

                // Wrap lifts dark side, steepness increases contrast
                ndl = (ndl + (half)_Wrap) * (half)_Steepness;
                return saturate(ndl);
            }

            

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                UNITY_SETUP_INSTANCE_ID(IN);
                UNITY_TRANSFER_INSTANCE_ID(IN, OUT);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(OUT);

                VertexPositionInputs posInputs = GetVertexPositionInputs(IN.positionOS.xyz);
                VertexNormalInputs   norInputs = GetVertexNormalInputs(IN.normalOS);

                OUT.positionCS  = posInputs.positionCS;
                OUT.positionWS  = posInputs.positionWS;
                OUT.normalWS    = (half3)normalize(norInputs.normalWS);
                OUT.uv          = TRANSFORM_TEX(IN.uv, _BaseMap);

                OUT.shadowCoord = GetShadowCoord(posInputs);
                OUT.fogFactor   = ComputeFogFactor(OUT.positionCS.z);
                return OUT;
            }

            half4 frag(Varyings IN) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(IN);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(IN);

                half3 albedo = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, IN.uv).rgb * (half3)_BaseColor.rgb;

                half3 N = normalize(IN.normalWS);
                half3 V = (half3)normalize(GetWorldSpaceViewDir(IN.positionWS));

                // -----------------------------
                // Main Light
                // -----------------------------
                Light mainLight = GetMainLight(IN.shadowCoord);
                half3 L = (half3)normalize(mainLight.direction);

                // Godot-like diffuse driver (wrap + steepness), then quantize to steps
                half diff01 = DiffuseDriver01(N, L);
                half ramp   = ToonRamp(diff01, (half)_Steps, (half)_RampSmooth);

                // Stylized shadow (0 shadow, 1 light)
                half shadow = StylizedShadow((half)mainLight.shadowAttenuation);

                half3 litToon = albedo * ramp;

                // Shadow tint blend
                half3 shadowTint = min((half3)_ShadowTint.rgb, 1.0h.xxx);
                half3 shadowToon = litToon * shadowTint;

                half shadowAmount = (1.0h - shadow) * (half)_ShadowDarkness;
                half3 color = lerp(litToon, shadowToon, shadowAmount);
                color *= (half3)mainLight.color;


                // Specular (banded). Multiply by shadow to keep highlight mostly in lit region.
                {
                    half3 H = normalize(L + V);
                    half nh = saturate(dot(N, H));
                    half specRaw = pow(nh, (half)_SpecPower);

                    half specBand = Band(specRaw, (half)_SpecThreshold, (half)_SpecSoftness);
                    color += (half3)_SpecColor.rgb * specBand * (half)_SpecStrength * shadow * (half3)mainLight.color;
                }

                // Rim (banded). Usually fine without shadow gating.
                {
                    half rimBase = 1.0h - saturate(dot(N, V));
                    half rimRaw  = pow(rimBase, (half)_RimPower);

                    half rimBand = Band(rimRaw, (half)_RimThreshold, (half)_RimSoftness);
                    half rimGate = shadow; // 0=shadow, 1=lit
                    color += (half3)_RimColor.rgb * rimBand * (half)_RimStrength * rimGate * (half3)mainLight.color;

                }

                // -------------------------------------------------------------
                // Additional Lights (Hard-Quantized, Range-aligned, No Physical Falloff)
                // - Range rings are based on dist/range, so the outer ring matches gizmo range.
                // - Quantization is inclusive inside range (no "missing last band").
                // - No URP distanceAttenuation fade (flat bands).
                // -------------------------------------------------------------
                #if defined(_ADDITIONAL_LIGHTS)
                {
                    uint count = GetAdditionalLightsCount();
                    for (uint li = 0u; li < count; li++)
                    {
                        Light light = GetAdditionalLight(li, IN.positionWS);

                        // --- Diffuse band (angle) ---
                        half3 La = (half3)normalize(light.direction);
                        half diff01   = DiffuseDriver01(N, La);
                        half diffRamp = ToonRamp(diff01, (half)_Steps, (half)_RampSmooth);

                        // Defaults (directional additional lights: no range rings)
                        half rangeRamp = 1.0h;

                        // --- Range rings (dist / range) ---
                        uint lightIndex = GetPerObjectLightIndex(li);
                        float4 posWS = _AdditionalLightsPosition[lightIndex];
                        float4 att   = _AdditionalLightsAttenuation[lightIndex];

                        if (posWS.w > 0.0) // point/spot
                        {
                            float invRangeSqr = max(att.x, 1e-6);
                            float range = rsqrt(invRangeSqr);
                            float dist  = length(posWS.xyz - IN.positionWS);

                            // 1 at center, 0 at range boundary
                            half radius01 = saturate(1.0h - (half)(dist / range));

                            // Hard inclusive quantization:
                            // - inside range: minimum band is 1/s (never 0)
                            // - outside range: forced 0
                            half s = max((half)_RangeSteps, 1.0h);

                            // inclusive bands: ceil(x*s)/s gives 1/s..1 inside, 0 when x==0
                            rangeRamp = ceil(radius01 * s) / s;

                            // hard cutoff outside range
                            rangeRamp *= (half)step(dist, range);

                            // contrast shaping
                            rangeRamp = pow(saturate(rangeRamp), max((half)_RangeContrast, 0.01h));
                        }

                        // --- Combine angle band and range ring band ---
                        half rampA = diffRamp * rangeRamp;

                        // --- Stylized shadow (0 shadow, 1 light) ---
                        half shA = StylizedShadow((half)light.shadowAttenuation);

                        // Shadow tint blend
                        half3 litA    = albedo * rampA;
                        half3 shadowA = albedo * (half3)_ShadowTint.rgb;
                        half shadowAmountA = (1.0h - shA) * (half)_ShadowDarkness;
                        half3 diffA   = lerp(litA, shadowA, shadowAmountA);

                        // IMPORTANT: keep band strength (do NOT binary-step it)
                        color += diffA * (half3)light.color;
                    }
                }
                #endif

                color = MixFog(color, IN.fogFactor);
                return half4(color, 1.0h);
            }
            ENDHLSL
        }

        // ============================================================
        // PASS 2: DepthNormals Pass (for outline post-processing)
        // ============================================================
        Pass
        {
            Name "DepthNormals"
            Tags { "LightMode" = "DepthNormals" }

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_instancing

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                half3  normalWS   : TEXCOORD0;

                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                UNITY_SETUP_INSTANCE_ID(IN);
                UNITY_TRANSFER_INSTANCE_ID(IN, OUT);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(OUT);

                OUT.positionCS = TransformObjectToHClip(IN.positionOS.xyz);
                OUT.normalWS   = (half3)normalize(TransformObjectToWorldNormal(IN.normalOS));
                return OUT;
            }

            half4 frag(Varyings IN) : SV_Target
            {
                half3 enc = IN.normalWS * 0.5h + 0.5h;
                return half4(enc, 0.0h);
            }
            ENDHLSL
        }

        UsePass "Universal Render Pipeline/Lit/ShadowCaster"
    }
}
