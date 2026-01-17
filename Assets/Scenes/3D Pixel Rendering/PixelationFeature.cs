using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

public class PixelationFeature : ScriptableRendererFeature
{
    [System.Serializable]
    public class Settings
    {
        [Header("Target low resolution (height only, width auto)")]
        public int targetHeight = 180;

        [Header("Overscan pixels (usually 1)")]
        [Range(0, 4)]
        public int overscanPixels = 1;

        [Header("Blit material (Shader: Pixel/PixelationBlit_URP)")]
        public Material blitMaterial;

        [Header("When to apply")]
        public RenderPassEvent passEvent = RenderPassEvent.AfterRenderingTransparents;
        // 若你后面要把 Outline/后处理一起像素化，建议改为 AfterRenderingPostProcessing
        // public RenderPassEvent passEvent = RenderPassEvent.AfterRenderingPostProcessing;
    }

    public Settings settings = new Settings();

    class PixelationPass : ScriptableRenderPass
    {
        private readonly Settings _settings;
        private readonly int _lowResTexId = Shader.PropertyToID("_PixelLowResTex");

        public PixelationPass(Settings settings)
        {
            _settings = settings;
            renderPassEvent = settings.passEvent;

            ConfigureInput(ScriptableRenderPassInput.Depth);
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            if (_settings.blitMaterial == null) return;
            if (renderingData.cameraData.isSceneViewCamera) return;

            CommandBuffer cmd = CommandBufferPool.Get("PixelationPass");

            // 1) 计算可视目标分辨率（保持宽高比）
            float aspect = (float)renderingData.cameraData.camera.pixelWidth / renderingData.cameraData.camera.pixelHeight;

            int visibleH = Mathf.Max(1, _settings.targetHeight);
            int visibleW = Mathf.Max(1, Mathf.RoundToInt(visibleH * aspect));

            // 2) overscan（边框像素）
            int o = Mathf.Max(0, _settings.overscanPixels);
            int lowH = visibleH + 2 * o;
            int lowW = visibleW + 2 * o;

            // 3) 申请低分辨率 RT（含 overscan），并强制 Point
            RenderTextureDescriptor desc = renderingData.cameraData.cameraTargetDescriptor;
            desc.depthBufferBits = 0;
            desc.msaaSamples = 1;
            desc.width = lowW;
            desc.height = lowH;

            cmd.GetTemporaryRT(_lowResTexId, desc, FilterMode.Point);

            // 4) 获取相机颜色目标
#if UNITY_2022_2_OR_NEWER
            RTHandle cameraColor = renderingData.cameraData.renderer.cameraColorTargetHandle;
            RenderTargetIdentifier cameraColorId = cameraColor.nameID;
#else
            RenderTargetIdentifier cameraColorId = renderingData.cameraData.renderer.cameraColorTarget;
#endif

            // 5) Downsample：Full -> Low（建议用默认 Blit，不要用 point 材质）
            //    这一步目的是把画面写入低分辨率 RT（含 overscan）
            cmd.SetGlobalTexture("_MainTex", cameraColorId);
            Blit(cmd, cameraColorId, _lowResTexId, _settings.blitMaterial);

            // 6) 给放大 shader 传参（亚像素补偿会用到）
            cmd.SetGlobalVector("_VisibleSize", new Vector4(visibleW, visibleH, 0, 0));
            cmd.SetGlobalVector("_LowResSize", new Vector4(lowW, lowH, 0, 0));
            cmd.SetGlobalVector("_OverscanPixels", new Vector4(o, o, 0, 0));
            // _SubPixelOffsetPixels 由 PixelSnapOrthoCamera 每帧写入全局参数

            // 7) Upsample：Low -> Full（用你的 Pixel/PixelationBlit_URP，内部 Point + 补偿）
            cmd.SetGlobalTexture("_MainTex", _lowResTexId);
            Blit(cmd, _lowResTexId, cameraColorId, _settings.blitMaterial);

            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
        }

        public override void FrameCleanup(CommandBuffer cmd)
        {
            if (cmd == null) return;
            cmd.ReleaseTemporaryRT(_lowResTexId);
        }
    }

    PixelationPass _pass;

    public override void Create()
    {
        _pass = new PixelationPass(settings);
    }

    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        if (settings.blitMaterial == null) return;
        renderer.EnqueuePass(_pass);
    }
}
