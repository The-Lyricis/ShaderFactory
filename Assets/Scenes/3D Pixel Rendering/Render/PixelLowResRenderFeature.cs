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

        [Tooltip("Material using Shader \"Pixel/NormalsOnly_URP\" (or your equivalent)")]
        public Material normalsOverrideMaterial;

        [Header("Render Transparents into LowRes")]
        public bool renderTransparents = true;

        [Header("Pass Events")]
        // Runs after URP opaques, before URP transparents (good place to build low-res buffers)
        public RenderPassEvent lowResPassEvent = RenderPassEvent.BeforeRenderingTransparents;
        // Runs after URP transparents, so we can overwrite final color with pixel output
        public RenderPassEvent blitPassEvent = RenderPassEvent.AfterRenderingTransparents;

        [Header("Background (Solid Color)")]
        public bool useCameraBackground = true;
        public Color backgroundColor = Color.black;
    }

    public Settings settings = new Settings();

    // ------------------------------------------------------------------
    // Shared per-camera data (RT ids + sizes).
    // ------------------------------------------------------------------
    class Shared
    {
        public int visibleW, visibleH;
        public int lowW, lowH;
        public int overscan;

        public Color clearColor;
        public bool allocatedThisFrame;

        public readonly int LowResColorId  = Shader.PropertyToID("_PixelLowResColorTex");
        public readonly int LowResDepthId  = Shader.PropertyToID("_PixelDepthTex");
        public readonly int LowResNormalId = Shader.PropertyToID("_PixelNormalTex");

        public readonly List<ShaderTagId> ShaderTags = new List<ShaderTagId>
        {
            new ShaderTagId("UniversalForward"),
            new ShaderTagId("UniversalForwardOnly"),
            new ShaderTagId("SRPDefaultUnlit"),
            new ShaderTagId("LightweightForward"),
        };

        public FilteringSettings filteringOpaque;
        public FilteringSettings filteringTransparent;
        public RenderStateBlock stateBlock;

        public Shared(LayerMask layerMask)
        {
            filteringOpaque      = new FilteringSettings(RenderQueueRange.opaque, layerMask);
            filteringTransparent = new FilteringSettings(RenderQueueRange.transparent, layerMask);
            stateBlock = new RenderStateBlock(RenderStateMask.Nothing);
        }
    }

    // ============================================================
    // PASS A: Render Opaques into LowResColor + LowResDepth
    // ============================================================
    class LowResOpaquePass : ScriptableRenderPass
    {
        readonly Settings _s;
        readonly Shared _sh;
        readonly ProfilingSampler _profiling = new ProfilingSampler("Pixel LowRes Opaque");

        public LowResOpaquePass(Settings s, Shared sh)
        {
            _s = s;
            _sh = sh;
            renderPassEvent = s.lowResPassEvent;
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            if (_s.blitMaterial == null) return;
            if (renderingData.cameraData.isSceneViewCamera) return;

            var cam = renderingData.cameraData.camera;

            // ---------- Compute sizes ----------
            float aspect = (float)cam.pixelWidth / cam.pixelHeight;

            _sh.visibleH = Mathf.Max(1, _s.targetHeight);
            _sh.visibleW = Mathf.Max(1, Mathf.RoundToInt(_sh.visibleH * aspect));

            _sh.overscan = Mathf.Max(0, _s.overscanPixels);
            _sh.lowH = _sh.visibleH + 2 * _sh.overscan;
            _sh.lowW = _sh.visibleW + 2 * _sh.overscan;

            _sh.clearColor = _s.useCameraBackground ? cam.backgroundColor : _s.backgroundColor;
            _sh.allocatedThisFrame = true;

            CommandBuffer cmd = CommandBufferPool.Get("PixelLowResOpaquePass");
            using (new ProfilingScope(cmd, _profiling))
            {
                // ---------- Allocate low-res color ----------
                var colorDesc = renderingData.cameraData.cameraTargetDescriptor;
                colorDesc.depthBufferBits = 0;
                colorDesc.msaaSamples = 1;
                colorDesc.width = _sh.lowW;
                colorDesc.height = _sh.lowH;

                cmd.GetTemporaryRT(_sh.LowResColorId, colorDesc, FilterMode.Point);

                // ---------- Allocate low-res depth (real depth buffer) ----------
                cmd.GetTemporaryRT(
                    _sh.LowResDepthId,
                    _sh.lowW, _sh.lowH,
                    24,
                    FilterMode.Point,
                    RenderTextureFormat.Depth
                );

                // ---------- Set RT + Clear ----------
                cmd.SetRenderTarget(
                    _sh.LowResColorId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store,
                    _sh.LowResDepthId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store
                );
                cmd.ClearRenderTarget(true, true, _sh.clearColor);

                context.ExecuteCommandBuffer(cmd);
                cmd.Clear();

                // ---------- Draw Opaques ----------
                var drawing = CreateDrawingSettings(_sh.ShaderTags, ref renderingData, SortingCriteria.CommonOpaque);
                context.DrawRenderers(renderingData.cullResults, ref drawing, ref _sh.filteringOpaque, ref _sh.stateBlock);

                // Expose for later passes/shaders
                cmd.SetGlobalTexture("_PixelDepthTex", _sh.LowResDepthId);
                cmd.SetGlobalTexture("_PixelLowResColorTex", _sh.LowResColorId);

                context.ExecuteCommandBuffer(cmd);
            }
            CommandBufferPool.Release(cmd);
        }
    }

    // ============================================================
    // PASS B: Render Normals into LowResNormal (reusing LowResDepth)
    // ============================================================
    class LowResNormalsPass : ScriptableRenderPass
    {
        readonly Settings _s;
        readonly Shared _sh;
        readonly ProfilingSampler _profiling = new ProfilingSampler("Pixel LowRes Normals");

        public LowResNormalsPass(Settings s, Shared sh)
        {
            _s = s;
            _sh = sh;
            renderPassEvent = s.lowResPassEvent; // same stage as opaque pass
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            if (!_s.enableNormals) return;
            if (_s.normalsOverrideMaterial == null) return;
            if (_s.blitMaterial == null) return;
            if (renderingData.cameraData.isSceneViewCamera) return;
            if (!_sh.allocatedThisFrame) return;

            CommandBuffer cmd = CommandBufferPool.Get("PixelLowResNormalsPass");
            using (new ProfilingScope(cmd, _profiling))
            {
                cmd.GetTemporaryRT(_sh.LowResNormalId, _sh.lowW, _sh.lowH, 0, FilterMode.Point, RenderTextureFormat.ARGB32);

                // Render normals, keep depth from opaque
                cmd.SetRenderTarget(
                    _sh.LowResNormalId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store,
                    _sh.LowResDepthId,  RenderBufferLoadAction.Load,     RenderBufferStoreAction.Store
                );

                // Encoded (0,0,1) => (0.5,0.5,1)
                cmd.ClearRenderTarget(false, true, new Color(0.5f, 0.5f, 1f, 1f));

                context.ExecuteCommandBuffer(cmd);
                cmd.Clear();

                var drawing = CreateDrawingSettings(_sh.ShaderTags, ref renderingData, SortingCriteria.CommonOpaque);
                drawing.overrideMaterial = _s.normalsOverrideMaterial;

                context.DrawRenderers(renderingData.cullResults, ref drawing, ref _sh.filteringOpaque, ref _sh.stateBlock);

                cmd.SetGlobalTexture("_PixelNormalTex", _sh.LowResNormalId);

                context.ExecuteCommandBuffer(cmd);
            }
            CommandBufferPool.Release(cmd);
        }
    }

    // ============================================================
    // PASS C: Render Transparents into LowResColor (keeps Opaque)
    // ============================================================
    class LowResTransparentPass : ScriptableRenderPass
    {
        readonly Settings _s;
        readonly Shared _sh;
        readonly ProfilingSampler _profiling = new ProfilingSampler("Pixel LowRes Transparent");

        public LowResTransparentPass(Settings s, Shared sh)
        {
            _s = s;
            _sh = sh;
            renderPassEvent = s.lowResPassEvent; // still before URP transparents, but we draw ours into low-res
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            if (!_s.renderTransparents) return;
            if (_s.blitMaterial == null) return;
            if (renderingData.cameraData.isSceneViewCamera) return;
            if (!_sh.allocatedThisFrame) return;

            CommandBuffer cmd = CommandBufferPool.Get("PixelLowResTransparentPass");
            using (new ProfilingScope(cmd, _profiling))
            {
                // Load existing low-res color (opaque already drawn), keep depth for correct occlusion.
                cmd.SetRenderTarget(
                    _sh.LowResColorId, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store,
                    _sh.LowResDepthId, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store
                );

                context.ExecuteCommandBuffer(cmd);
                cmd.Clear();

                // Transparent sorting is important.
                var drawing = CreateDrawingSettings(_sh.ShaderTags, ref renderingData, SortingCriteria.CommonTransparent);
                context.DrawRenderers(renderingData.cullResults, ref drawing, ref _sh.filteringTransparent, ref _sh.stateBlock);

                // Keep globals consistent
                cmd.SetGlobalTexture("_PixelLowResColorTex", _sh.LowResColorId);

                context.ExecuteCommandBuffer(cmd);
            }
            CommandBufferPool.Release(cmd);
        }
    }

    // ============================================================
    // PASS D: Final blit to camera target + release RTs
    // ============================================================
    class FinalBlitPass : ScriptableRenderPass
    {
        readonly Settings _s;
        readonly Shared _sh;
        readonly ProfilingSampler _profiling = new ProfilingSampler("Pixel Final Blit");

        public FinalBlitPass(Settings s, Shared sh)
        {
            _s = s;
            _sh = sh;
            renderPassEvent = s.blitPassEvent;
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            if (_s.blitMaterial == null) return;
            if (renderingData.cameraData.isSceneViewCamera) return;
            if (!_sh.allocatedThisFrame) return;

            CommandBuffer cmd = CommandBufferPool.Get("PixelFinalBlitPass");
            using (new ProfilingScope(cmd, _profiling))
            {
#if UNITY_2022_2_OR_NEWER
                var cameraColor = renderingData.cameraData.renderer.cameraColorTargetHandle;
                RenderTargetIdentifier cameraColorId = cameraColor.nameID;
#else
                RenderTargetIdentifier cameraColorId = renderingData.cameraData.renderer.cameraColorTarget;
#endif

                cmd.SetGlobalVector("_VisibleSize", new Vector4(_sh.visibleW, _sh.visibleH, 0, 0));
                cmd.SetGlobalVector("_LowResSize",  new Vector4(_sh.lowW, _sh.lowH, 0, 0));
                cmd.SetGlobalVector("_OverscanPixels", new Vector4(_sh.overscan, _sh.overscan, 0, 0));

                // Your blit shader samples _MainTex
                cmd.SetGlobalTexture("_MainTex", _sh.LowResColorId);

                Blit(cmd, _sh.LowResColorId, cameraColorId, _s.blitMaterial);

                // Release all temporaries here
                cmd.ReleaseTemporaryRT(_sh.LowResColorId);
                cmd.ReleaseTemporaryRT(_sh.LowResDepthId);
                if (_s.enableNormals && _s.normalsOverrideMaterial != null)
                    cmd.ReleaseTemporaryRT(_sh.LowResNormalId);

                _sh.allocatedThisFrame = false;

                context.ExecuteCommandBuffer(cmd);
            }
            CommandBufferPool.Release(cmd);
        }
    }

    Shared _shared;
    LowResOpaquePass _opaquePass;
    LowResNormalsPass _normalsPass;
    LowResTransparentPass _transparentPass;
    FinalBlitPass _blitPass;

    public override void Create()
    {
        _shared = new Shared(settings.layerMask);

        _opaquePass      = new LowResOpaquePass(settings, _shared);
        _normalsPass     = new LowResNormalsPass(settings, _shared);
        _transparentPass = new LowResTransparentPass(settings, _shared);
        _blitPass        = new FinalBlitPass(settings, _shared);
    }

    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        if (settings.blitMaterial == null) return;

        renderer.EnqueuePass(_opaquePass);

        if (settings.enableNormals && settings.normalsOverrideMaterial != null)
            renderer.EnqueuePass(_normalsPass);

        // NEW: draw transparents into low-res color (so pixel result contains them)
        if (settings.renderTransparents)
            renderer.EnqueuePass(_transparentPass);

        renderer.EnqueuePass(_blitPass);
    }
}
