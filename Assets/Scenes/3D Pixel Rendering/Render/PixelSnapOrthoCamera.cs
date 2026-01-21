using UnityEngine;

/// <summary>
/// Pixel-grid snapping for Orthographic Camera.
/// Attach this to the Camera GameObject (child of your Pivot).
/// 
/// What it does:
/// 1) Snaps camera position to a world-space pixel grid (grid follows camera orientation).
/// 2) Computes the sub-pixel residual in "pixel units" for optional screen-space compensation.
/// 
/// Requirements:
/// - Camera must be Orthographic.
/// - targetPixelHeight should match your low-res render height (e.g., 360 for 640x360).
/// </summary>
[DefaultExecutionOrder(1000)] // Execute late to run after pivot rotation & follow logic
public class PixelSnapOrthoCamera : MonoBehaviour
{
    [Header("Match your pixelation RT height (e.g., 360 for 640x360)")]
    [Min(1)]
    public int targetPixelHeight = 360;

    [Header("Snap axes (usually XY only for iso/2.5D)")]
    public bool snapZ = false;

    [Header("Enable/Disable snapping")]
    public bool enableSnap = true;

    /// <summary>
    /// Residual offset in pixel units (not UV).
    /// Use this for a final blit pass: uv -= subPixelOffsetPixels / pixelSize.
    /// </summary>
    public Vector2 SubPixelOffsetPixels { get; private set; }

    Camera _cam;
    UnityEngine.Rendering.Universal.UniversalAdditionalCameraData _data;

    void Awake()
    {
        _cam = GetComponent<Camera>();
        _data = _cam.GetComponent<UnityEngine.Rendering.Universal.UniversalAdditionalCameraData>();
    }

    void OnEnable()
    {
        if (!_cam) return;

        if (!_data) return;

        // Force depth texture so URP generates _CameraDepthTexture.
        _data.requiresDepthTexture = true;
        Debug.LogWarning("[PixelSnapOrthoCamera] Enabled requiresDepthTexture on URP Additional Camera Data.");

        // Enable opaque texture if you need refraction sampling.
        _data.requiresColorTexture = true;
    }

    void LateUpdate()
    {
        if (!enableSnap) return;
        if (_cam == null) _cam = GetComponent<Camera>();
        if (_cam == null || !_cam.orthographic) return;

        // 1) World-space size of a single pixel (Orthographic only)
        // vertical world height covered by camera = 2 * orthographicSize
        float pixelSizeWorld = (2f * _cam.orthographicSize) / targetPixelHeight;

        // 2) Desired position (in a real follow camera, this should be the computed target position)
        Vector3 desiredWorld = transform.position;

        // 3) Snap in camera-local space so the "grid" rotates with camera orientation
        Vector3 local = transform.InverseTransformPoint(desiredWorld);

        Vector3 snappedLocal = local;
        snappedLocal.x = Mathf.Round(local.x / pixelSizeWorld) * pixelSizeWorld;
        snappedLocal.y = Mathf.Round(local.y / pixelSizeWorld) * pixelSizeWorld;

        if (snapZ)
            snappedLocal.z = Mathf.Round(local.z / pixelSizeWorld) * pixelSizeWorld;

        Vector3 snappedWorld = transform.TransformPoint(snappedLocal);

        // 4) Compute residual (desired - snapped), convert to pixel units
        Vector3 residualWorld = desiredWorld - snappedWorld;
        Vector3 residualLocal = transform.InverseTransformVector(residualWorld);

        SubPixelOffsetPixels = new Vector2(
            residualLocal.x / pixelSizeWorld,
            residualLocal.y / pixelSizeWorld
        );

        // 5) Apply snapped camera position (this removes jitter)
        transform.position = snappedWorld;

        // Optional: expose residual as a global shader parameter for your final blit
        Shader.SetGlobalVector("_SubPixelOffsetPixels",
            new Vector4(SubPixelOffsetPixels.x, SubPixelOffsetPixels.y, 0f, 0f));

        // Optional: also expose pixel size for convenience
        Shader.SetGlobalVector("_PixelGridSize",
            new Vector4(0f, 0f, targetPixelHeight, pixelSizeWorld));
    }
}
