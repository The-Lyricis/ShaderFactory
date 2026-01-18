Shader "Pixel/PixelationBlit_URP"
{
    Properties
    {
        // --- Depth outline (external silhouette) ---
        [Header(Depth Outline Settings)]
        [Toggle] _EnableDepthOutline   ("Enable Depth Outline", Float) = 1
        _DepthThreshold        ("Depth Threshold", Range(0.0001, 0.2)) = 0.003
        _DepthStrength         ("Depth Strength", Range(0, 1)) = 0.85
        // Darken amount for silhouette: 0 = no darkening, 1 = fully black
        _DepthDarkenAmount     ("Depth Darken Amount", Range(0, 1)) = 0.65

        // --- Normal outline (internal edges) ---
        [Header(Normal Outline Settings)]
        [Toggle] _EnableNormalOutline  ("Enable Normal Outline", Float) = 1
        _NormalThreshold       ("Normal Threshold", Range(0.01, 1.0)) = 0.18
        _NormalStrength        ("Normal Strength", Range(0, 1)) = 0.25
        // Lighten amount for internal edges: 0 = no lightening, 1 = fully white
        _NormalLightenAmount   ("Normal Lighten Amount", Range(0, 1)) = 0.35

        // --- Debug Tools ---
        [Header(Debug Tools)]
        // KeywordEnum creates a professional dropdown menu
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

            // Low-res buffers produced by the renderer feature
            TEXTURE2D(_MainTex);
            TEXTURE2D(_PixelDepthTex);
            TEXTURE2D(_PixelNormalTex);

            // Nearest-neighbor sampling to preserve pixel grid
            SAMPLER(sampler_PointClamp);

            // Visible pixel grid (no overscan), e.g. 640x360
            float2 _VisibleSize;
            // Low-res RT size (with overscan), e.g. (Pw+2o, Ph+2o)
            float2 _LowResSize;
            // Overscan pixels (usually 1,1)
            float2 _OverscanPixels;
            // Subpixel camera compensation in pixel units
            float4 _SubPixelOffsetPixels;

            // Depth outline
            float _EnableDepthOutline;
            float _DepthThreshold;
            float _DepthStrength;
            float _DepthDarkenAmount;

            // Normal outline
            float _EnableNormalOutline;
            float _NormalThreshold;
            float _NormalStrength;
            float _NormalLightenAmount;

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
            // Depth helpers (Linear01)
            // -----------------------------
            float Depth01(float2 uv)
            {
                float raw = SAMPLE_TEXTURE2D(_PixelDepthTex, sampler_PointClamp, uv).r;
                return Linear01Depth(raw, _ZBufferParams);
            }

            // Sobel 3x3 edge detector on Linear01 depth (binary output 0/1)
            float SobelDepthEdge01(float2 uv, float2 texel, float threshold)
            {
                float d00 = Depth01(uv + texel * float2(-1,  1));
                float d10 = Depth01(uv + texel * float2( 0,  1));
                float d20 = Depth01(uv + texel * float2( 1,  1));
                float d01 = Depth01(uv + texel * float2(-1,  0));
                float d11 = Depth01(uv + texel * float2( 0,  0));
                float d21 = Depth01(uv + texel * float2( 1,  0));
                float d02 = Depth01(uv + texel * float2(-1, -1));
                float d12 = Depth01(uv + texel * float2( 0, -1));
                float d22 = Depth01(uv + texel * float2( 1, -1));

                float gx = (-1*d00 + 1*d20) + (-2*d01 + 2*d21) + (-1*d02 + 1*d22);
                float gy = ( 1*d00 + 2*d10 + 1*d20) + (-1*d02 - 2*d12 - 1*d22);

                float g = abs(gx) + abs(gy);
                return step(threshold, g);
            }

            // -----------------------------
            // Normal helpers (decode + edge)
            // -----------------------------
            float3 NormalWS(float2 uv)
            {
                float3 enc = SAMPLE_TEXTURE2D(_PixelNormalTex, sampler_PointClamp, uv).rgb;
                return normalize(enc * 2.0 - 1.0);
            }

            // Stable normal edge metric: 1 - dot(nC, nNeighbor)
            float NormalEdge01(float2 uvC, float2 uvR, float2 uvU, float threshold)
            {
                float3 nC = NormalWS(uvC);
                float3 nR = NormalWS(uvR);
                float3 nU = NormalWS(uvU);
                float diffR = 1.0 - dot(nC, nR);
                float diffU = 1.0 - dot(nC, nU);
                float diff  = max(diffR, diffU);
                return step(threshold, diff);
            }

            // -----------------------------
            // Pixel-grid mapping (screen UV -> low-res UV)
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

            // Apply silhouette outline by darkening the object's own color.
            float3 ApplyDepthDarken(float3 baseRgb, float edge01)
            {
                float w = saturate(edge01 * _DepthStrength);
                float darkFactor = 1.0 - saturate(_DepthDarkenAmount);
                return lerp(baseRgb, baseRgb * darkFactor, w);
            }

            // Apply internal outline by lightening the object's own color.
            float3 ApplyNormalLighten(float3 baseRgb, float edge01)
            {
                float w = saturate(edge01 * _NormalStrength);
                float a = saturate(_NormalLightenAmount);
                float3 lightened = baseRgb + (1.0 - baseRgb) * a;
                return lerp(baseRgb, lightened, w);
            }

            half4 Frag(Varyings i) : SV_Target
            {
                float2 uvMin, uvMax;
                float2 uvLow = ComputeLowResUV(i.uv, uvMin, uvMax);

                // --- Debug views handling ---
                if (_DebugView == 1) // Normals
                {
                    float3 encN = SAMPLE_TEXTURE2D(_PixelNormalTex, sampler_PointClamp, uvLow).rgb;
                    return half4(encN, 1);
                }
                if (_DebugView == 2) // Depth
                {
                    float raw = SAMPLE_TEXTURE2D(_PixelDepthTex, sampler_PointClamp, uvLow).r;
                    return half4(raw, raw, raw, 1);
                }

                // --- Base color ---
                half4 col = SAMPLE_TEXTURE2D(_MainTex, sampler_PointClamp, uvLow);

                // Low-res texel step
                float2 texelLow = 1.0 / _LowResSize;
                float2 uvR = clamp(uvLow + float2(texelLow.x, 0.0), uvMin, uvMax);
                float2 uvU = clamp(uvLow + float2(0.0, texelLow.y), uvMin, uvMax);

                // Gate: treat depth ~ 1 as background
                float dC = Depth01(uvLow);
                bool hasGeo = (dC < 0.999);

                float eD = 0.0;
                // --- Depth silhouette outline ---
                if (hasGeo && _EnableDepthOutline > 0.5)
                {
                    eD = SobelDepthEdge01(uvLow, texelLow, _DepthThreshold);
                    col.rgb = ApplyDepthDarken(col.rgb, eD);
                }

                // --- Normal internal outline (suppressed on silhouette) ---
                if (hasGeo && _EnableNormalOutline > 0.5)
                {
                    float eN = NormalEdge01(uvLow, uvR, uvU, _NormalThreshold);
                    // Avoid double-stroking on the silhouette edge
                    eN *= (1.0 - eD);
                    col.rgb = ApplyNormalLighten(col.rgb, eN);
                }

                return col;
            }
            ENDHLSL
        }
    }
}