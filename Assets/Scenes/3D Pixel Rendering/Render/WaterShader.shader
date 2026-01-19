Shader "Debug/DepthOutput"
{
    Properties
    {
        _DepthRange ("Depth Display Range", Range(0.1, 50)) = 10.0
        _DebugRange ("Range", Range(0.1, 100)) = 10.0
    }
    SubShader
    {
        Tags { "RenderPipeline"="UniversalPipeline" "Queue"="Transparent" "RenderType"="Transparent" }

        Pass
        {
            ZWrite Off
            Blend One Zero

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            
            // 关键：包含 URP 深度采样库
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"

            struct Attributes {
                float4 positionOS : POSITION;
            };

            struct Varyings {
                float4 positionCS : SV_POSITION;
                float4 screenPos : TEXCOORD0;
            };

            float _DepthRange;
            float _DebugRange;

            Varyings vert(Attributes IN) {
                Varyings OUT;
                VertexPositionInputs pos = GetVertexPositionInputs(IN.positionOS.xyz);
                OUT.positionCS = pos.positionCS;
                OUT.screenPos = ComputeScreenPos(OUT.positionCS);
                return OUT;
            }

half4 frag(Varyings IN) : SV_Target {
    float2 uv = IN.screenPos.xy / IN.screenPos.w;
    
    // 1. 获取原始深度
    float rawDepth = SampleSceneDepth(uv);
    
    // 2. 转换线性深度 (兼容正交和透视)
    float linearDepth;
    if (unity_OrthoParams.w > 0.0) {
        // 正交相机处理
        #if UNITY_REVERSED_Z
            linearDepth = (_ProjectionParams.y + (_ProjectionParams.z - _ProjectionParams.y) * (1.0 - rawDepth));
        #else
            linearDepth = (_ProjectionParams.y + (_ProjectionParams.z - _ProjectionParams.y) * rawDepth);
        #endif
    } else {
        // 透视相机处理
        linearDepth = LinearEyeDepth(rawDepth, _ZBufferParams);
    }

    // 3. 输出显示
    // 如果还是黑，把材质球上的 _DebugRange 调小（比如 0.5）
    // 如果还是黑，请检查下方是否有物体
    float display = saturate(linearDepth / _DebugRange);
    return half4(display.xxx, 1.0);
}
            ENDHLSL
        }
    }
}