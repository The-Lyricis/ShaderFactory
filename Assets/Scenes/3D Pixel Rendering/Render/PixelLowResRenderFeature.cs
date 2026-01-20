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

        [Header("Layer mask (all objects rendered into low-res)")]
        public LayerMask layerMask = ~0;

        [Header("Final blit material (Shader: Pixel/PixelationBlit_URP)")]
        public Material blitMaterial;

        [Header("Normals (for inner outlines)")]
        public bool enableNormals = true;

        [Tooltip("Material using Shader \"Pixel/NormalsOnly_URP\"")]
        public Material normalsOverrideMaterial;

        [Header("Render Transparents into LowRes Color")]
        public bool renderTransparents = true;

        [Header("Transparents -> Depth/Normals (for outlines)")]
        [Tooltip("If ON: draws transparent objects' DepthOnly pass into low-res depth.\nWarning: may break multi-layer transparency blending (back layers can be depth-culled).")]
        public bool transparentWriteDepth = true;

        [Tooltip("If ON: draws transparent objects into low-res normals using normalsOverrideMaterial.")]
        public bool transparentWriteNormals = true;

        [Header("Pass Events")]
        // Build low-res buffers after URP opaques, before URP transparents
        public RenderPassEvent lowResPassEvent = RenderPassEvent.BeforeRenderingTransparents;
        // Overwrite final color after URP transparents
        public RenderPassEvent blitPassEvent = RenderPassEvent.AfterRenderingTransparents;

        [Header("Background (Solid Color)")]
        public bool useCameraBackground = true;
        public Color backgroundColor = Color.black;
    }

    public Settings settings = new Settings();

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

        public readonly List<ShaderTagId> ForwardTags = new List<ShaderTagId>
        {
            new ShaderTagId("UniversalForward"),
            new ShaderTagId("UniversalForwardOnly"),
            new ShaderTagId("SRPDefaultUnlit"),
            new ShaderTagId("LightweightForward"),
        };

        public readonly List<ShaderTagId> DepthOnlyTags = new List<ShaderTagId>
        {
            new ShaderTagId("DepthOnly"),
        };

        public FilteringSettings filteringOpaque;
        public FilteringSettings filteringTransparent;

        public RenderStateBlock stateBlock;

        public Shared(LayerMask mask)
        {
            filteringOpaque      = new FilteringSettings(RenderQueueRange.opaque, mask);
            filteringTransparent = new FilteringSettings(RenderQueueRange.transparent, mask);
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

            // Refresh filtering every frame (supports inspector edits)
            _sh.filteringOpaque      = new FilteringSettings(RenderQueueRange.opaque, _s.layerMask);
            _sh.filteringTransparent = new FilteringSettings(RenderQueueRange.transparent, _s.layerMask);

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

                // ---------- Allocate low-res depth ----------
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
                var drawing = CreateDrawingSettings(_sh.ForwardTags, ref renderingData, SortingCriteria.CommonOpaque);
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
    // PASS B: Transparent DepthOnly -> LowResDepth (for outlines)
    // ============================================================
    class LowResTransparentDepthPass : ScriptableRenderPass
    {
        readonly Settings _s;
        readonly Shared _sh;
        readonly ProfilingSampler _profiling = new ProfilingSampler("Pixel LowRes Transparent Depth");

        public LowResTransparentDepthPass(Settings s, Shared sh)
        {
            _s = s;
            _sh = sh;
            renderPassEvent = s.lowResPassEvent;
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            if (!_s.renderTransparents) return;
            if (!_s.transparentWriteDepth) return;
            if (_s.blitMaterial == null) return;
            if (renderingData.cameraData.isSceneViewCamera) return;
            if (!_sh.allocatedThisFrame) return;

            CommandBuffer cmd = CommandBufferPool.Get("PixelLowResTransparentDepthPass");
            using (new ProfilingScope(cmd, _profiling))
            {
                // Keep existing color, write to the SAME depth (DepthOnly pass should ColorMask 0)
                cmd.SetRenderTarget(
                    _sh.LowResColorId, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store,
                    _sh.LowResDepthId, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store
                );

                context.ExecuteCommandBuffer(cmd);
                cmd.Clear();

                var drawing = CreateDrawingSettings(_sh.DepthOnlyTags, ref renderingData, SortingCriteria.CommonOpaque);
                context.DrawRenderers(renderingData.cullResults, ref drawing, ref _sh.filteringTransparent, ref _sh.stateBlock);

                // Keep globals consistent
                cmd.SetGlobalTexture("_PixelDepthTex", _sh.LowResDepthId);
                context.ExecuteCommandBuffer(cmd);
            }
            CommandBufferPool.Release(cmd);
        }
    }

    // ============================================================
    // PASS C: Opaque Normals -> LowResNormal (reuse LowResDepth)
    // ============================================================
    class LowResNormalsPass : ScriptableRenderPass
    {
        readonly Settings _s;
        readonly Shared _sh;
        readonly ProfilingSampler _profiling = new ProfilingSampler("Pixel LowRes Opaque Normals");

        public LowResNormalsPass(Settings s, Shared sh)
        {
            _s = s;
            _sh = sh;
            renderPassEvent = s.lowResPassEvent;
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

                // Render normals, keep depth
                cmd.SetRenderTarget(
                    _sh.LowResNormalId, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store,
                    _sh.LowResDepthId,  RenderBufferLoadAction.Load,     RenderBufferStoreAction.Store
                );

                // Encoded (0,0,1) => (0.5,0.5,1)
                cmd.ClearRenderTarget(false, true, new Color(0.5f, 0.5f, 1f, 1f));

                context.ExecuteCommandBuffer(cmd);
                cmd.Clear();

                var drawing = CreateDrawingSettings(_sh.ForwardTags, ref renderingData, SortingCriteria.CommonOpaque);
                drawing.overrideMaterial = _s.normalsOverrideMaterial;

                context.DrawRenderers(renderingData.cullResults, ref drawing, ref _sh.filteringOpaque, ref _sh.stateBlock);

                cmd.SetGlobalTexture("_PixelNormalTex", _sh.LowResNormalId);
                context.ExecuteCommandBuffer(cmd);
            }
            CommandBufferPool.Release(cmd);
        }
    }

    // ============================================================
    // PASS D: Transparent Normals -> LowResNormal (reuse LowResDepth)
    // ============================================================
    class LowResTransparentNormalsPass : ScriptableRenderPass
    {
        readonly Settings _s;
        readonly Shared _sh;
        readonly ProfilingSampler _profiling = new ProfilingSampler("Pixel LowRes Transparent Normals");

        public LowResTransparentNormalsPass(Settings s, Shared sh)
        {
            _s = s;
            _sh = sh;
            renderPassEvent = s.lowResPassEvent;
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            if (!_s.renderTransparents) return;
            if (!_s.enableNormals) return;
            if (!_s.transparentWriteNormals) return;
            if (_s.normalsOverrideMaterial == null) return;
            if (_s.blitMaterial == null) return;
            if (renderingData.cameraData.isSceneViewCamera) return;
            if (!_sh.allocatedThisFrame) return;

            CommandBuffer cmd = CommandBufferPool.Get("PixelLowResTransparentNormalsPass");
            using (new ProfilingScope(cmd, _profiling))
            {
                // IMPORTANT: load existing normals written by opaque normals pass
                cmd.SetRenderTarget(
                    _sh.LowResNormalId, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store,
                    _sh.LowResDepthId,  RenderBufferLoadAction.Load, RenderBufferStoreAction.Store
                );

                context.ExecuteCommandBuffer(cmd);
                cmd.Clear();

                var drawing = CreateDrawingSettings(_sh.ForwardTags, ref renderingData, SortingCriteria.CommonOpaque);
                drawing.overrideMaterial = _s.normalsOverrideMaterial;

                context.DrawRenderers(renderingData.cullResults, ref drawing, ref _sh.filteringTransparent, ref _sh.stateBlock);

                cmd.SetGlobalTexture("_PixelNormalTex", _sh.LowResNormalId);
                context.ExecuteCommandBuffer(cmd);
            }
            CommandBufferPool.Release(cmd);
        }
    }

    // ============================================================
    // PASS E: Render Transparents Color -> LowResColor (reuse LowResDepth)
    // ============================================================
    class LowResTransparentColorPass : ScriptableRenderPass
    {
        readonly Settings _s;
        readonly Shared _sh;
        readonly ProfilingSampler _profiling = new ProfilingSampler("Pixel LowRes Transparent Color");

        public LowResTransparentColorPass(Settings s, Shared sh)
        {
            _s = s;
            _sh = sh;
            renderPassEvent = s.lowResPassEvent;
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            if (!_s.renderTransparents) return;
            if (_s.blitMaterial == null) return;
            if (renderingData.cameraData.isSceneViewCamera) return;
            if (!_sh.allocatedThisFrame) return;

            CommandBuffer cmd = CommandBufferPool.Get("PixelLowResTransparentColorPass");
            using (new ProfilingScope(cmd, _profiling))
            {
                cmd.SetRenderTarget(
                    _sh.LowResColorId, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store,
                    _sh.LowResDepthId, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store
                );

                context.ExecuteCommandBuffer(cmd);
                cmd.Clear();

                // Transparent sorting is important for blending
                var drawing = CreateDrawingSettings(_sh.ForwardTags, ref renderingData, SortingCriteria.CommonTransparent);
                context.DrawRenderers(renderingData.cullResults, ref drawing, ref _sh.filteringTransparent, ref _sh.stateBlock);

                cmd.SetGlobalTexture("_PixelLowResColorTex", _sh.LowResColorId);
                context.ExecuteCommandBuffer(cmd);
            }
            CommandBufferPool.Release(cmd);
        }
    }

    // ============================================================
    // PASS F: Final blit + release
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

                // Blit shader samples _MainTex
                cmd.SetGlobalTexture("_MainTex", _sh.LowResColorId);

                Blit(cmd, _sh.LowResColorId, cameraColorId, _s.blitMaterial);

                // Release
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
    LowResTransparentDepthPass _transparentDepthPass;
    LowResNormalsPass _opaqueNormalsPass;
    LowResTransparentNormalsPass _transparentNormalsPass;
    LowResTransparentColorPass _transparentColorPass;
    FinalBlitPass _blitPass;

    public override void Create()
    {
        _shared = new Shared(settings.layerMask);

        _opaquePass = new LowResOpaquePass(settings, _shared);
        _transparentDepthPass = new LowResTransparentDepthPass(settings, _shared);
        _opaqueNormalsPass = new LowResNormalsPass(settings, _shared);
        _transparentNormalsPass = new LowResTransparentNormalsPass(settings, _shared);
        _transparentColorPass = new LowResTransparentColorPass(settings, _shared);
        _blitPass = new FinalBlitPass(settings, _shared);
    }

    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        if (settings.blitMaterial == null) return;

        // Order matters within the same RenderPassEvent:
        // Opaque -> (Transparent depth for outlines) -> Opaque normals -> Transparent normals -> Transparent color -> Final blit
        renderer.EnqueuePass(_opaquePass);

        if (settings.renderTransparents && settings.transparentWriteDepth)
            renderer.EnqueuePass(_transparentDepthPass);

        if (settings.enableNormals && settings.normalsOverrideMaterial != null)
            renderer.EnqueuePass(_opaqueNormalsPass);

        if (settings.renderTransparents && settings.enableNormals && settings.transparentWriteNormals && settings.normalsOverrideMaterial != null)
            renderer.EnqueuePass(_transparentNormalsPass);

        if (settings.renderTransparents)
            renderer.EnqueuePass(_transparentColorPass);

        renderer.EnqueuePass(_blitPass);
    }
}
