Shader "Pixel/PixelationBlit_URP"
{
    Properties
    {
        // --- Depth outline (external silhouette) ---
        [Header(Depth Outline Settings)]
        [Toggle] _EnableDepthOutline   ("Enable Depth Outline", Float) = 1
        _DepthThreshold        ("Depth Threshold", Range(0.0001, 0.2)) = 0.003
        _DepthStrength         ("Depth Strength", Range(0, 1)) = 0.85
        _DepthDarkenAmount     ("Depth Darken Amount", Range(0, 1)) = 0.65
        _DepthPower            ("Depth Power", Range(0.1, 10.0)) = 1.0

        // Optional: smoothing width for depth edge (screen-stable)
        _DepthEdgeSoftness     ("Depth Edge Softness", Range(0.0, 0.2)) = 0.03

        // --- Normal outline (internal edges) ---
        [Header(Normal Outline Settings)]
        [Toggle] _EnableNormalOutline  ("Enable Normal Outline", Float) = 1
        _NormalThreshold       ("Normal Threshold", Range(0.0001, 1.0)) = 0.18
        _NormalStrength        ("Normal Strength", Range(0, 1)) = 0.25
        _NormalLightenAmount   ("Normal Lighten Amount", Range(0, 1)) = 0.35

        // Optional: smoothing width for normal edge
        _NormalEdgeSoftness    ("Normal Edge Softness", Range(0.0, 0.5)) = 0.08

        // --- Debug Tools ---
        [Header(Debug Tools)]
        [KeywordEnum(Final, Normals, Depth)] _DebugView ("Debug Mode", Float) = 0
    }

    SubShader
    {
        Tags { "RenderPipeline"="UniversalPipeline" "Queue"="Overlay" }

        Pass
        {
            Name "PixelationBlit"
            ZTest Always
            ZWrite Off
            Cull Off

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            TEXTURE2D(_MainTex);
            TEXTURE2D(_PixelDepthTex);
            TEXTURE2D(_PixelNormalTex);

            SAMPLER(sampler_PointClamp);

            float2 _VisibleSize;
            float2 _LowResSize;
            float2 _OverscanPixels;
            float4 _SubPixelOffsetPixels;

            float _EnableDepthOutline;
            float _DepthThreshold;
            float _DepthStrength;
            float _DepthDarkenAmount;
            float _DepthEdgeSoftness;
            float _DepthPower;

            float _EnableNormalOutline;
            float _NormalThreshold;
            float _NormalStrength;
            float _NormalLightenAmount;
            float _NormalEdgeSoftness;

            float _DebugView;

            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv         : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionHCS : SV_POSITION;
                float2 uv          : TEXCOORD0;
            };

            Varyings Vert(Attributes v)
            {
                Varyings o;
                o.positionHCS = TransformObjectToHClip(v.positionOS.xyz);
                o.uv = v.uv;
                return o;
            }

            // -----------------------------
            // Pixel-grid mapping
            // -----------------------------
            float2 ComputeLowResUV(float2 screenUV, out float2 uvMin, out float2 uvMax)
            {
                float2 pixel = floor(screenUV * _VisibleSize);
                float2 samplePixel = pixel + _OverscanPixels + 0.5 - _SubPixelOffsetPixels.xy;
                float2 uvLow = samplePixel / _LowResSize;

                uvMin = _OverscanPixels / _LowResSize;
                uvMax = (_VisibleSize + _OverscanPixels) / _LowResSize;
                return clamp(uvLow, uvMin, uvMax);
            }

            // -----------------------------
            // Depth helpers
            // -----------------------------
            float Depth01(float2 uv)
            {
                float depth = pow(SAMPLE_TEXTURE2D(_PixelDepthTex, sampler_PointClamp, uv).r, _DepthPower);
                return Linear01Depth(depth, _ZBufferParams);
            }

            // This tends to represent silhouette / discontinuities.
            float DepthEdgePos(float dC, float dU, float dD, float dL, float dR)
            {
                float edge = 0.0;

                edge += saturate(dU - dC);
                edge += saturate(dD - dC);
                edge += saturate(dL - dC);
                edge += saturate(dR - dC);
                return edge; // 0..4
            }

            // Used to suppress internal highlights near silhouette / occlusion.
            float DepthEdgeNeg(float dC, float dU, float dD, float dL, float dR)
            {
                float neg = 0.0;
                neg += saturate(dC - dU);
                neg += saturate(dC - dD);
                neg += saturate(dC - dL);
                neg += saturate(dC - dR);
                return neg; // 0..4
            }

            // Convert an accumulated edge response into a stable 0..1 mask
            float EdgeMask(float edgeAccum, float threshold, float softness)
            {
                // Normalize (0..4) -> (0..1)
                float e = edgeAccum * 0.25;

                // Soft threshold (more stable than step)
                float a = threshold * (1.0 - softness);
                float b = threshold * (1.0 + softness);
                return smoothstep(a, b, e);
            }

            // -----------------------------
            // Normal helpers
            // -----------------------------
            float3 NormalWS(float2 uv)
            {
                float3 enc = SAMPLE_TEXTURE2D(_PixelNormalTex, sampler_PointClamp, uv).rgb;
                return normalize(enc * 2.0 - 1.0);
            }

            //normalIndicator: use dot difference + depth gate
            float NormalIndicator(float3 baseN, float3 newN)
            {
                return saturate(1.0 - dot(baseN, newN));
            }

            // -----------------------------
            // Color application
            // -----------------------------
            float3 ApplyDepthDarken(float3 baseRgb, float edge01)
            {
                float w = saturate(edge01 * _DepthStrength);
                float darkFactor = 1.0 - saturate(_DepthDarkenAmount);
                return lerp(baseRgb, baseRgb * darkFactor, w);
            }

            float3 ApplyNormalLighten(float3 baseRgb, float edge01)
            {
                float w = saturate(edge01 * _NormalStrength);
                float a = saturate(_NormalLightenAmount);
                
                // Calculate luminance
                float lum = dot(baseRgb, float3(0.2126, 0.7152, 0.0722));
                
                // Calculate lightened color
                float3 lightened = baseRgb + (1.0 - baseRgb) * a * saturate(lum * 2.0); 
                
                return lerp(baseRgb, lightened, w);
            }

            half4 Frag(Varyings i) : SV_Target
            {
                float2 uvMin, uvMax;
                float2 uvLow = ComputeLowResUV(i.uv, uvMin, uvMax);

                // Debug views
                if (_DebugView == 1) // Normals
                {
                    float3 encN = SAMPLE_TEXTURE2D(_PixelNormalTex, sampler_PointClamp, uvLow).rgb;
                    return half4(encN, 1);
                }
                if (_DebugView == 2) // Depth (raw)
                {
                    float  depth= pow(SAMPLE_TEXTURE2D(_PixelDepthTex, sampler_PointClamp, uvLow).r, _DepthPower);
                    return half4(depth, depth, depth, 1);
                }

                half4 col = SAMPLE_TEXTURE2D(_MainTex, sampler_PointClamp, uvLow);

                float2 texel = 1.0 / _LowResSize;
                float2 uvU = clamp(uvLow + float2(0.0, -texel.y), uvMin, uvMax);
                float2 uvD = clamp(uvLow + float2(0.0,  texel.y), uvMin, uvMax);
                float2 uvL = clamp(uvLow + float2(-texel.x, 0.0), uvMin, uvMax);
                float2 uvR = clamp(uvLow + float2( texel.x, 0.0), uvMin, uvMax);

                // Depth samples (Linear01)
                float dC = Depth01(uvLow);
                bool hasGeo = (dC < 0.999);

                if (!hasGeo)
                    return col;

                float dU = Depth01(uvU);
                float dD = Depth01(uvD);
                float dL = Depth01(uvL);
                float dR = Depth01(uvR);

                // --- Depth edge (silhouette) + negative depth mask ---
                float depthPosAccum = DepthEdgePos(dC, dU, dD, dL, dR); // 0..4
                float depthNegAccum = DepthEdgeNeg(dC, dU, dD, dL, dR); // 0..4

                float eD = 0.0;
                float negMask = 0.0;

                if (_EnableDepthOutline > 0.5)
                {
                    // Convert to 0..1 edge mask, smooth threshold
                    eD = EdgeMask(depthPosAccum, _DepthThreshold, _DepthEdgeSoftness);
                    col.rgb = ApplyDepthDarken(col.rgb, eD);
                }

                // Always compute negMask if normals enabled, used to suppress overlaps
                if (_EnableNormalOutline > 0.5)
                {
                    float3 nC = NormalWS(uvLow);
                    
                    // Sample left and down neighbors (opposite of uvR/uvU) to keep edges inside the object.
                    float2 uvL_N = clamp(uvLow + float2(-texel.x, 0.0), uvMin, uvMax);
                    float2 uvD_N = clamp(uvLow + float2(0.0,  texel.y), uvMin, uvMax);
                    
                    float3 nL = NormalWS(uvL_N);
                    float3 nD = NormalWS(uvD_N);
                    float dL_N = Depth01(uvL_N);
                    float dD_N = Depth01(uvD_N);

                    // Compute normal differences.
                    float diffL = NormalIndicator(nC, nL);
                    float diffD = NormalIndicator(nC, nD);

                    // --- Key: depth gate ---
                    // Treat as internal corner only when neighbor depth is very close to center depth.
                    // Otherwise this is usually the outer silhouette edge.
                    float distThreshold = _DepthThreshold * 2.0; 
                    float maskL = step(abs(dC - dL_N), distThreshold);
                    float maskD = step(abs(dC - dD_N), distThreshold);

                    float nEdge = max(diffL * maskL, diffD * maskD);

                    // Threshold and smoothing.
                    float a = _NormalThreshold;
                    float b = _NormalThreshold + max(0.01, _NormalEdgeSoftness);
                    float eN = smoothstep(a, b, nEdge);

                    // Exclude pixels already classified as silhouette (eD).
                    eN *= (1.0 - eD);
                    
                    // Also avoid drawing on background (sky).
                    eN *= hasGeo ? 1.0 : 0.0;

                    col.rgb = ApplyNormalLighten(col.rgb, eN);
                }

                return col;
            }
            ENDHLSL
        }
    }
}
