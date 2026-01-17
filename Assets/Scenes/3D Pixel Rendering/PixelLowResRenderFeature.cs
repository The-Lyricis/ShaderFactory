using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

public class PixelLowResRenderFeature : ScriptableRendererFeature
{
    [System.Serializable]
    public class Settings
    {
        [Header("Target low resolution (height only, width auto)")]
        public int targetHeight = 180;

        [Header("Overscan pixels (usually 1)")]
        [Range(0, 4)]
        public int overscanPixels = 1;

        [Header("Layer mask to render into low-res buffers")]
        public LayerMask layerMask = ~0;

        [Header("Final blit material (Shader: Pixel/PixelationBlit_URP)")]
        public Material blitMaterial;

        [Header("Normals (for inner outlines)")]
        public bool enableNormals = true;
        public Material normalsOverrideMaterial; // Material using Shader "Pixel/NormalsOnly_URP"

        [Header("When to render low-res scene")]
        public RenderPassEvent passEvent = RenderPassEvent.BeforeRenderingTransparents;

        [Header("Background (Solid Color)")]
        public bool useCameraBackground = true;
        public Color backgroundColor = Color.black;
    }

    public Settings settings = new Settings();

    class Pass : ScriptableRenderPass
    {
        static readonly int LowResColorId  = Shader.PropertyToID("_PixelLowResColorTex");
        static readonly int LowResDepthId  = Shader.PropertyToID("_PixelDepthTex");
        static readonly int LowResNormalId = Shader.PropertyToID("_PixelNormalTex");

        readonly Settings _s;
        readonly ProfilingSampler _profiling = new ProfilingSampler("PixelLowResRenderPass");

        readonly List<ShaderTagId> _shaderTags = new List<ShaderTagId>
        {
            new ShaderTagId("UniversalForward"),
            new ShaderTagId("UniversalForwardOnly"),
            new ShaderTagId("SRPDefaultUnlit"),
            new ShaderTagId("LightweightForward"),
        };

        FilteringSettings _filteringOpaque;
        RenderStateBlock _stateBlock;

        public Pass(Settings s)
        {
            _s = s;
            renderPassEvent = s.passEvent;

            _filteringOpaque = new FilteringSettings(RenderQueueRange.opaque, s.layerMask);
            _stateBlock = new RenderStateBlock(RenderStateMask.Nothing);
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            if (_s.blitMaterial == null) return;
            if (renderingData.cameraData.isSceneViewCamera) return;

            var cam = renderingData.cameraData.camera;

            float aspect = (float)cam.pixelWidth / cam.pixelHeight;

            int visibleH = Mathf.Max(1, _s.targetHeight);
            int visibleW = Mathf.Max(1, Mathf.RoundToInt(visibleH * aspect));

            int o = Mathf.Max(0, _s.overscanPixels);
            int lowH = visibleH + 2 * o;
            int lowW = visibleW + 2 * o;

            Color clearCol = _s.useCameraBackground ? cam.backgroundColor : _s.backgroundColor;

            CommandBuffer cmd = CommandBufferPool.Get("PixelLowResRenderPass");
            using (new ProfilingScope(cmd, _profiling))
            {
                // --- Allocate low-res color RT
                var colorDesc = renderingData.cameraData.cameraTargetDescriptor;
                colorDesc.depthBufferBits = 0;
                colorDesc.msaaSamples = 1;
                colorDesc.width = lowW;
                colorDesc.height = lowH;

                cmd.GetTemporaryRT(LowResColorId, colorDesc, FilterMode.Point);

                // --- Allocate low-res depth RT (real depth buffer)
                cmd.GetTemporaryRT(
                    LowResDepthId,
                    lowW, lowH,
                    24,
                    FilterMode.Point,
                    RenderTextureFormat.Depth
                );

                // --- Optional: allocate low-res normal RT
                if (_s.enableNormals)
                {
                    // ARGB32 is enough for encoded normals
                    cmd.GetTemporaryRT(LowResNormalId, lowW, lowH, 0, FilterMode.Point, RenderTextureFormat.ARGB32);
                }

                // --- Render opaque into low-res color + depth
                cmd.SetRenderTarget(
                    LowResColorId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store,
                    LowResDepthId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store
                );
                cmd.ClearRenderTarget(true, true, clearCol);

                context.ExecuteCommandBuffer(cmd);
                cmd.Clear();

                var drawingOpaque = CreateDrawingSettings(_shaderTags, ref renderingData, SortingCriteria.CommonOpaque);
                context.DrawRenderers(renderingData.cullResults, ref drawingOpaque, ref _filteringOpaque, ref _stateBlock);

                // --- Render normals into low-res normal + (same) depth
                if (_s.enableNormals && _s.normalsOverrideMaterial != null)
                {
                    cmd.SetRenderTarget(
                        LowResNormalId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store,
                        LowResDepthId, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store
                    );

                    // 清成“默认向上法线”(0,0,1) 编码 = (0.5,0.5,1)
                    cmd.ClearRenderTarget(false, true, new Color(0.5f, 0.5f, 1f, 1f));
                    context.ExecuteCommandBuffer(cmd);
                    cmd.Clear();

                    var drawingNormals = CreateDrawingSettings(_shaderTags, ref renderingData, SortingCriteria.CommonOpaque);
                    drawingNormals.overrideMaterial = _s.normalsOverrideMaterial;

                    context.DrawRenderers(renderingData.cullResults, ref drawingNormals, ref _filteringOpaque, ref _stateBlock);

                    // 输出到全局，供 blit shader 采样
                    cmd.SetGlobalTexture("_PixelNormalTex", LowResNormalId);
                }

                // --- Final blit to camera color target
#if UNITY_2022_2_OR_NEWER
                var cameraColor = renderingData.cameraData.renderer.cameraColorTargetHandle;
                RenderTargetIdentifier cameraColorId = cameraColor.nameID;
#else
                RenderTargetIdentifier cameraColorId = renderingData.cameraData.renderer.cameraColorTarget;
#endif

                // Pass params to shader
                cmd.SetGlobalVector("_VisibleSize", new Vector4(visibleW, visibleH, 0, 0));
                cmd.SetGlobalVector("_LowResSize",  new Vector4(lowW, lowH, 0, 0));
                cmd.SetGlobalVector("_OverscanPixels", new Vector4(o, o, 0, 0));

                // Provide depth texture to shader
                cmd.SetGlobalTexture("_PixelDepthTex", LowResDepthId);

                // Color source
                cmd.SetGlobalTexture("_MainTex", LowResColorId);
                Blit(cmd, LowResColorId, cameraColorId, _s.blitMaterial);

                // Cleanup
                cmd.ReleaseTemporaryRT(LowResColorId);
                cmd.ReleaseTemporaryRT(LowResDepthId);
                if (_s.enableNormals) cmd.ReleaseTemporaryRT(LowResNormalId);
            }

            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
        }
    }

    Pass _pass;

    public override void Create()
    {
        _pass = new Pass(settings);
    }

    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        if (settings.blitMaterial == null) return;
        renderer.EnqueuePass(_pass);
    }
}
