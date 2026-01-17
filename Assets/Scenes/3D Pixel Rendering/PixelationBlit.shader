Shader "Pixel/PixelationBlit_URP"
{
    Properties
    {
        // Depth outline (external)
        _EnableDepthOutline("Enable Depth Outline", Float) = 1
        _DepthThreshold("Depth Threshold", Range(0.0001, 0.05)) = 0.003
        _DepthStrength("Depth Strength", Range(0, 1)) = 0.85
        _DepthOutlineColor("Depth Outline Color", Color) = (0,0,0,1)

        // Normal outline (internal)
        _EnableNormalOutline("Enable Normal Outline", Float) = 1
        _NormalThreshold("Normal Threshold", Range(0.01, 1.0)) = 0.18
        _NormalStrength("Normal Strength", Range(0, 1)) = 0.25
        _NormalOutlineColor("Normal Outline Color", Color) = (1,1,1,1)

        _DebugView("Debug View (0=Final, 1=Normals, 2=Depth)", Float) = 0
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

            float2 _VisibleSize;      // (Pw, Ph)
            float2 _LowResSize;       // (Pw+2o, Ph+2o)
            float2 _OverscanPixels;   // (o, o)
            float4 _SubPixelOffsetPixels; // (dx, dy, 0, 0)

            float _EnableDepthOutline;
            float _DepthThreshold;
            float _DepthStrength;
            float4 _DepthOutlineColor;

            float _EnableNormalOutline;
            float _NormalThreshold;
            float _NormalStrength;
            float4 _NormalOutlineColor;

            float _DebugView;

            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionHCS : SV_POSITION;
                float2 uv : TEXCOORD0;
            };

            Varyings Vert(Attributes v)
            {
                Varyings o;
                o.positionHCS = TransformObjectToHClip(v.positionOS.xyz);
                o.uv = v.uv;
                return o;
            }

            float Depth01(float2 uv)
            {
                float raw = SAMPLE_TEXTURE2D(_PixelDepthTex, sampler_PointClamp, uv).r;
                return Linear01Depth(raw, _ZBufferParams);
            }

            float DepthEdge01(float2 uvC, float2 uvR, float2 uvU, float threshold)
            {
                float dC = Depth01(uvC);
                float dR = Depth01(uvR);
                float dU = Depth01(uvU);
                float diff = max(abs(dC - dR), abs(dC - dU));
                return step(threshold, diff);
            }

            float3 NormalWS(float2 uv)
            {
                float3 enc = SAMPLE_TEXTURE2D(_PixelNormalTex, sampler_PointClamp, uv).rgb;
                return normalize(enc * 2.0 - 1.0);
            }

            float NormalEdge01(float2 uvC, float2 uvR, float2 uvU, float threshold)
            {
                float3 nC = NormalWS(uvC);
                float3 nR = NormalWS(uvR);
                float3 nU = NormalWS(uvU);

                float diff = max(length(nC - nR), length(nC - nU));
                return step(threshold, diff);
            }

            half4 Frag(Varyings i) : SV_Target
            {
                float2 vis = _VisibleSize;
                float2 low = _LowResSize;

                float2 pixel = floor(i.uv * vis);

                // Low-res color uv (with overscan + subpixel compensation)
                float2 samplePixel = pixel + _OverscanPixels + 0.5 - _SubPixelOffsetPixels.xy;
                float2 uvLow = samplePixel / low;

                float2 uvMin = _OverscanPixels / low;
                float2 uvMax = (vis + _OverscanPixels) / low;
                uvLow = clamp(uvLow, uvMin, uvMax);

                half4 col = SAMPLE_TEXTURE2D(_MainTex, sampler_PointClamp, uvLow);

                // Neighbor uv in low-res
                float2 texelLow = 1.0 / low;
                float2 uvR = clamp(uvLow + float2(texelLow.x, 0), uvMin, uvMax);
                float2 uvU = clamp(uvLow + float2(0, texelLow.y), uvMin, uvMax);

                // Gate: avoid outlining background
                float dC = Depth01(uvLow);
                bool hasGeo = (dC < 0.999);

                // Depth outline (external)
                float eD = 0;
                if (hasGeo && _EnableDepthOutline > 0.5)
                {
                    eD = DepthEdge01(uvLow, uvR, uvU, _DepthThreshold);
                    col.rgb = lerp(col.rgb, _DepthOutlineColor.rgb, eD * _DepthStrength);
                }

                // Normal outline (internal)
                if (hasGeo && _EnableNormalOutline > 0.5)
                {
                    float eN = NormalEdge01(uvLow, uvR, uvU, _NormalThreshold);

                    eN *= (1.0 - eD);
                    col.rgb = lerp(col.rgb, _NormalOutlineColor.rgb, eN * _NormalStrength);
                }

                // ===== Debug Views =====
                if (_DebugView > 0.5 && _DebugView < 1.5)
                {
                    // Normals: store is encoded [0,1], so just show it directly
                    float3 encN = SAMPLE_TEXTURE2D(_PixelNormalTex, sampler_PointClamp, uvLow).rgb;
                    return half4(encN, 1);
                }
                else if (_DebugView >= 1.5)
                {
                    // Depth: visualize Linear01 depth
                    float raw = SAMPLE_TEXTURE2D(_PixelDepthTex, sampler_PointClamp, uvLow).r;
                    return half4(raw, raw, raw, 1);
                }


                return col;
            }
            ENDHLSL
        }
    }
}
