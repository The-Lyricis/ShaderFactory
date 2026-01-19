using UnityEngine;

public class LightingController : MonoBehaviour
{
    [Header("轨道与总体设置")]
    public Transform centerTarget;
    public float dayCycleSpeed = 10f;
    [Tooltip("靠近地平线时的速度倍率")]
    public float horizonSpeedMultiplier = 0.2f;

    [Header("太阳设置 (子物体)")]
    public Light sunLight;
    public float maxSunIntensity = 1.2f;

    [Header("篝火点光源设置 (子物体)")]
    public Light campFireLight;
    public float fireDayIntensity = 0.5f;
    public float fireNightIntensity = 2.5f;
    public float fireDayRange = 3f;
    public float fireNightRange = 8f;

    [Header("篝火闪烁效果")]
    public Color colorMin = new Color(1f, 0.4f, 0.1f);
    public Color colorMax = new Color(1f, 0.6f, 0.2f);
    public float flickerSpeed = 8f;
    public float flickerIntensityStrength = 0.3f;

    private float _noiseOffset;

    void Start()
    {
        _noiseOffset = Random.value * 100f;
        if (sunLight == null || campFireLight == null)
            Debug.LogWarning("请在 Inspector 中指定太阳和篝火的光源组件");
    }

    void Update()
    {
        UpdateSunOrbit();
        UpdateLightingEffects();
    }

    private void UpdateSunOrbit()
    {
        Vector3 center = centerTarget != null ? centerTarget.position : Vector3.zero;

        // 1. 计算动态旋转速度 (靠近地平线时变慢)
        float heightFactor = Mathf.Abs(sunLight.transform.forward.y); 
        float dynamicSpeed = Mathf.Lerp(dayCycleSpeed * horizonSpeedMultiplier, dayCycleSpeed, heightFactor);

        // 2. 旋转太阳
        sunLight.transform.RotateAround(center, Vector3.right, dynamicSpeed * Time.deltaTime);
        sunLight.transform.LookAt(center);
    }

    private void UpdateLightingEffects()
    {
        // 计算白昼权重: 1 为正午, 0 为地平线以下 (夜晚)
        // 使用 Vector3.down 因为太阳 forward 指向地心时是正午
        float dayWeight = Mathf.Clamp01(Vector3.Dot(sunLight.transform.forward, Vector3.down));

        // --- 1. 太阳强度更新 ---
        sunLight.intensity = Mathf.Lerp(0.05f, maxSunIntensity, dayWeight);
        sunLight.shadows = dayWeight > 0.1f ? LightShadows.Soft : LightShadows.None;

        // --- 2. 篝火逻辑更新 ---
        if (campFireLight != null)
        {
            // A. 基础强度与半径随昼夜变化 (白天低, 晚上高)
            float baseIntensity = Mathf.Lerp(fireNightIntensity, fireDayIntensity, dayWeight);
            float currentRange = Mathf.Lerp(fireNightRange, fireDayRange, dayWeight);
            
            // B. 模拟火焰闪烁 (使用柏林噪声)
            float noise = Mathf.PerlinNoise(Time.time * flickerSpeed, _noiseOffset);
            float flicker = (noise - 0.5f) * 2f * flickerIntensityStrength; // 产生 -strength 到 +strength 的波动

            // C. 应用颜色变换 (在暖色调间微变)
            campFireLight.color = Color.Lerp(colorMin, colorMax, noise);

            // D. 最终赋值
            campFireLight.intensity = baseIntensity + flicker;
            campFireLight.range = currentRange + flicker * 0.5f; // 半径随之轻微抖动
        }
    }
}