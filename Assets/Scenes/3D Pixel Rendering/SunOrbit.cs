using UnityEngine;

public class RealisticSunOrbit : MonoBehaviour
{
    [Header("轨道设置")]
    public Transform centerTarget;
    [Tooltip("正午时的基础旋转速度")]
    public float baseSpeed = 10f;
    [Tooltip("靠近地平线时的速度倍率 (0.1代表变慢10倍)")]
    public float horizonSpeedMultiplier = 0.2f;

    [Header("光照设置")]
    public float maxIntensity = 1.2f;
    [Range(0, 1)]
    public float sunsetThreshold = 0.1f; // 太阳离地平线多近时开始关灯

    private Light sunLight;

    void Start()
    {
        sunLight = GetComponent<Light>();
    }

    void Update()
    {
        Vector3 center = centerTarget != null ? centerTarget.position : Vector3.zero;

        // 1. 计算当前的物理速度
        // transform.forward.y 的范围是 [-1 (正午), 1 (半夜)]
        // 我们取其绝对值的偏移量，越靠近地平线（y趋近0），速度越慢
        float heightFactor = Mathf.Abs(transform.forward.y); 
        // 使用 SmoothStep 让速度变化更平滑，避免突变
        float dynamicSpeed = Mathf.Lerp(baseSpeed * horizonSpeedMultiplier, baseSpeed, heightFactor);

        // 2. 执行旋转
        transform.RotateAround(center, Vector3.right, dynamicSpeed * Time.deltaTime);
        transform.LookAt(center);

        // 3. 物理光照模拟：基于角度的强度平滑过渡
        // dot 产品计算灯光方向与地面法线(Up)的反向关系
        float lightAngle = Vector3.Dot(transform.forward, Vector3.down);
        
        if (lightAngle > sunsetThreshold)
        {
            // 太阳升起：根据角度计算强度，实现晨曦到正午的平滑增强
            float intensityScale = Mathf.Clamp01((lightAngle - sunsetThreshold) / 0.2f);
            sunLight.intensity = intensityScale * maxIntensity;
            sunLight.shadows = LightShadows.Soft;
        }
        else
        {
            // 太阳落下
            sunLight.intensity = Mathf.MoveTowards(sunLight.intensity, 0, Time.deltaTime);
            sunLight.shadows = LightShadows.None;
        }
    }
}