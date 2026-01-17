Shader "Custom/MeshErosion"
{
    Properties
    {
        // Surface / lighting
        _BaseColor   ("Base Color", Color)                 = (1,1,1,1)
        _WireColor   ("Wire Color", Color)                 = (0,0,0,1)
        _SpecColor   ("Specular Color", Color)             = (1,1,1,1)
        _Shininess   ("Shininess", Range(1,128))           = 16
        _WireWidth   ("Wire Width", Range(0.001, 0.8))     = 0.5
        _Feather     ("Wire Feather", Range(0.0001, 0.05)) = 0.01

        // Random displacement (erosion-like effect)
        _DisplaceAmount ("Displace Amount", Range(0.0, 2.0))    = 0.5   // Max offset distance
        _DisplaceChance ("Displace Chance", Range(0.0, 1.0))    = 0.3   // Probability a vertex is active in a segment
        _DisplaceDir    ("Displace Direction", Vector)          = (1,0,0,0) // World-space direction
        _DisplaceScale  ("Displace Noise Scale", Range(0.1,10)) = 1.0   // Random pattern scale

        // Time control + half-space plane
        _DisplaceSpeed  ("Random Speed (segments/sec)", Range(0.0, 20.0)) = 3.0 // How fast each vertex progresses its own timeline
        _DisplacePlane  ("Displace Plane", Float)                          = 0.0 // Cut plane position along DisplaceDir
    }

    SubShader
    {
        Tags
        {
            "RenderType"     = "Opaque"
            "Queue"          = "Geometry"
            "RenderPipeline" = "UniversalPipeline"
        }
        LOD 200

        Pass
        {
            Name "MeshErosionWireframe"
            Tags { "LightMode" = "UniversalForward" }

            Cull Off
            ZWrite On
            Blend Off

            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex   vert
            #pragma geometry geom
            #pragma fragment frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            // Material / lighting parameters
            float4 _BaseColor;
            float4 _WireColor;
            float  _WireWidth;
            float  _Feather;
            float4 _SpecColor;
            float  _Shininess;

            // Displacement parameters
            float  _DisplaceAmount;
            float  _DisplaceChance;
            float4 _DisplaceDir;
            float  _DisplaceScale;

            float  _DisplaceSpeed;
            float  _DisplacePlane;

            // ------------------------------------------------------------
            // Utility: hash functions
            // ------------------------------------------------------------

            // float3 -> float in [0,1]
            float Hash13(float3 p)
            {
                p = frac(p * 0.1031);
                p += dot(p, p.yzx + 33.33);
                return frac((p.x + p.y) * p.z);
            }

            // float2 -> float in [0,1] (for per-vertex, per-segment randomness)
            float Hash21(float2 p)
            {
                float3 q = float3(p.x, p.y, p.x + p.y);
                return Hash13(q);
            }

            // ------------------------------------------------------------
            // Vertex / Geometry / Fragment structures
            // ------------------------------------------------------------
            struct Attributes
            {
                float3 positionOS : POSITION;
                float3 normalOS   : NORMAL;
            };

            struct V2G
            {
                float4 positionHCS : SV_POSITION; // Clip space
                float3 positionWS  : TEXCOORD0;   // World position
                float3 normalWS    : TEXCOORD1;   // World normal
            };

            struct G2F
            {
                float4 positionHCS : SV_POSITION;
                float3 bary        : TEXCOORD0;   // Barycentric coordinates for wireframe
                float3 worldN      : TEXCOORD1;   // World normal
                float3 worldPos    : TEXCOORD2;   // World position
            };

            // ------------------------------------------------------------
            // Vertex shader:
            // Each vertex has its own time line:
            //   localTime = _Time.y * _DisplaceSpeed + seed * K
            // For each integer segment of localTime:
            //   - we roll a random 'active' flag for this vertex
            //   - if active: displacement grows from 0 → max in that segment
            //   - next segment: may be active or inactive, and previous offset snaps back to origin
            // ------------------------------------------------------------
            V2G vert (Attributes v)
            {
                V2G o;

                float3 posWS = TransformObjectToWorld(float4(v.positionOS, 1.0)).xyz;
                float3 nWS   = TransformObjectToWorldNormal(v.normalOS);

                // Normalized displacement direction in world space
                float3 dir = normalize(_DisplaceDir.xyz);

                // ----------------------
                // 1) Half-space mask
                // ----------------------
                float proj = dot(posWS, dir);
                float sideMask = step(_DisplacePlane, proj);

                // ----------------------
                // 2) Per-vertex base seed
                // ----------------------
                // Stable in space (no time): each vertex gets a unique seed in [0,1]
                float seed = Hash13(posWS * _DisplaceScale);

                // ----------------------
                // 3) Per-vertex local time
                // ----------------------
                float localTime = 0.0;
                if (_DisplaceSpeed > 0.0)
                {
                    localTime = _Time.y * _DisplaceSpeed + seed * 100.0; // offset by seed so segments are de-synced
                }
                // if _DisplaceSpeed == 0 → localTime remains 0 → everything static

                // Segment index and in-segment progress
                float segment   = floor(localTime);       // which integer segment this vertex is in
                float segmentT  = frac(localTime);        // 0..1 progress inside this segment

                // ----------------------
                // 4) Per-vertex, per-segment random decision
                // ----------------------
                // Use (seed, segment) as input for per-vertex per-segment randomness
                float rndActive = Hash21(float2(seed, segment)); // 0..1

                // Is this vertex active in this segment?
                float active = step(rndActive, _DisplaceChance * 0.01); // 1 = active, 0 = inactive

                // Separate random for amplitude, based only on seed
                float rndAmp = seed;
                float amp    = 1.0 - rndAmp; // smaller seed → larger amplitude

                // ----------------------
                // 5) Final displacement strength for this frame
                // ----------------------
                // segmentT: 0 → 1 within the segment
                // active: if 0, vertex is at origin (no offset) for this whole segment
                // When active:
                //   strength grows from 0 → (amp) during this segment.
                float strength = sideMask * active * amp * segmentT;

                // Apply displacement along dir
                posWS += dir * (_DisplaceAmount * strength);

                o.positionWS  = posWS;
                o.normalWS    = nWS;
                o.positionHCS = TransformWorldToHClip(posWS);

                return o;
            }

            // ------------------------------------------------------------
            // Geometry shader: emit triangle with barycentric coordinates
            // ------------------------------------------------------------
            [maxvertexcount(3)]
            void geom(triangle V2G input[3], inout TriangleStream<G2F> triStream)
            {
                float3 bary[3] =
                {
                    float3(1,0,0),
                    float3(0,1,0),
                    float3(0,0,1)
                };

                [unroll]
                for (int i = 0; i < 3; i++)
                {
                    G2F o;
                    float3 posWS = input[i].positionWS;

                    o.positionHCS = TransformWorldToHClip(posWS);
                    o.bary        = bary[i];
                    o.worldN      = input[i].normalWS;
                    o.worldPos    = posWS;

                    triStream.Append(o);
                }
                // TriangleStream implicitly ends the primitive when the function returns
            }

            // ------------------------------------------------------------
            // Fragment shader: screen-space wireframe + URP main light + SH ambient
            // ------------------------------------------------------------
            half4 frag (G2F i) : SV_Target
            {
                // ---- Screen-space constant-width wireframe mask ----
                float3 bary = i.bary;
                float3 d    = fwidth(bary); // accounts for screen derivatives
                float3 s    = smoothstep(d * _WireWidth, d * (_WireWidth + _Feather), bary);
                float  wireMask = min(s.x, min(s.y, s.z)); // 0 = pure wire, 1 = pure fill

                // ---- Lighting: main directional light + SH ambient ----
                float3 N = normalize(i.worldN);
                float3 V = normalize(_WorldSpaceCameraPos - i.worldPos);

                Light  mainLight = GetMainLight();
                float3 L        = normalize(mainLight.direction);
                float3 lightCol = mainLight.color;

                float NdotL = max(0.0, dot(N, L));
                float3 H    = normalize(L + V);

                float spec = 0.0;
                if (NdotL > 0.0)
                {
                    spec = pow(max(0.0, dot(N, H)), max(1.0, _Shininess));
                }

                float3 ambient  = SampleSH(N) * _BaseColor.rgb;
                float3 diffuse  = lightCol * _BaseColor.rgb * NdotL;
                float3 specular = lightCol * _SpecColor.rgb * spec;

                float3 litColor = ambient + diffuse + specular;

                // ---- Combine lighting with wireframe ----
                half4 baseCol = half4(litColor, _BaseColor.a);
                half4 col     = lerp(_WireColor, baseCol, wireMask);

                col.a = 1.0;
                return col;
            }

            ENDHLSL
        }
    }

    FallBack Off
}
