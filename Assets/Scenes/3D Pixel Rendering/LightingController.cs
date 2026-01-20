using UnityEngine;

public class LightingController : MonoBehaviour
{
    [Header("轨道与时间设置")]
    public Transform centerTarget;
    public float dayDuration = 20f;      
    public float nightDuration = 10f;    

    [Header("太阳光感设置")]
    public Light sunLight;
    public float maxSunIntensity = 1.2f;
    public Gradient sunColorGradient;    
    public float maxAmbientIntensity = 1.0f;
    public float minAmbientIntensity = 0.2f;

    [Header("篝火核心设置")]
    public Light campFireLight;
    public float fireDayIntensity = 0.6f;
    public float fireNightIntensity = 2.0f;
    public float fireDayRange = 4f;
    public float fireNightRange = 10f;

    [Header("篝火-高频闪烁 (小幅度细节)")]
    public float flickerSpeed = 12f;
    public float flickerStrength = 0.15f;

    [Header("篝火-低频呼吸 (大范围柔和)")]
    public float breathSpeed = 1.5f;
    public float breathStrength = 0.4f;
    public Color fireColorMin = new Color(1f, 0.4f, 0.1f);
    public Color fireColorMax = new Color(1f, 0.55f, 0.2f);

    private float _currentDayTimer = 0f;
    private float _currentNightTimer = 0f;
    private bool _isDay = true;
    private float _noiseOffset;

    void Start()
    {
        _noiseOffset = Random.value * 100f;
        if (sunColorGradient == null) InitializeDefaultGradient();
    }

    void Update()
    {
        float dayWeight = 0f; 

        if (_isDay)
        {
            UpdateDaytime(out dayWeight);
        }
        else
        {
            UpdateNighttime();
            dayWeight = 0f; 
        }

        UpdateEnvironment(dayWeight);
        UpdateCampfire(dayWeight);
    }

    private void UpdateDaytime(out float dayWeight)
    {
        _currentDayTimer += Time.deltaTime;
        float progress = Mathf.Clamp01(_currentDayTimer / dayDuration);

        // 边缘减速曲线
        float smoothedProgress = Mathf.SmoothStep(0, 1, progress);

        // --- 核心修正：计算上方轨道 ---
        // 0度在左侧 (-1,0), 90度在上方 (0,1), 180度在右侧 (1,0)
        float angleRad = smoothedProgress * Mathf.PI; 
        Vector3 orbitOffset = new Vector3(-Mathf.Cos(angleRad), Mathf.Sin(angleRad), 0);

        Vector3 center = centerTarget != null ? centerTarget.position : Vector3.zero;
        sunLight.transform.position = center + orbitOffset * 20f; // 20f 为轨道半径
        sunLight.transform.LookAt(center);

        // dayWeight 在正午(smoothedProgress=0.5)时为 1
        dayWeight = Mathf.Sin(angleRad);

        if (_currentDayTimer >= dayDuration)
        {
            _isDay = false;
            _currentDayTimer = 0f;
        }
    }

    private void UpdateNighttime()
    {
        _currentNightTimer += Time.deltaTime;
        if (_currentNightTimer >= nightDuration)
        {
            _isDay = true;
            _currentNightTimer = 0f;
        }
    }

    private void UpdateEnvironment(float dayWeight)
    {
        sunLight.intensity = Mathf.Lerp(0f, maxSunIntensity, dayWeight);
        sunLight.color = sunColorGradient.Evaluate(dayWeight);
        sunLight.shadows = dayWeight > 0.1f ? LightShadows.Soft : LightShadows.None;
        RenderSettings.ambientIntensity = Mathf.Lerp(minAmbientIntensity, maxAmbientIntensity, dayWeight);
    }

    private void UpdateCampfire(float dayWeight)
    {
        if (campFireLight == null) return;

        float baseIntensity = Mathf.Lerp(fireNightIntensity, fireDayIntensity, dayWeight);
        float baseRange = Mathf.Lerp(fireNightRange, fireDayRange, dayWeight);

        float noise = Mathf.PerlinNoise(Time.time * flickerSpeed, _noiseOffset);
        float flicker = (noise - 0.5f) * 2f * flickerStrength;
        float breath = Mathf.Sin(Time.time * breathSpeed) * breathStrength;

        campFireLight.intensity = baseIntensity + flicker + breath;
        campFireLight.range = baseRange + (flicker + breath) * 0.5f;
        campFireLight.color = Color.Lerp(fireColorMin, fireColorMax, noise);
    }

    private void InitializeDefaultGradient()
    {
        sunColorGradient = new Gradient();
        var colorKeys = new GradientColorKey[3];
        colorKeys[0] = new GradientColorKey(new Color(1, 0.6f, 0.4f), 0.0f); // 日出橙
        colorKeys[1] = new GradientColorKey(Color.white, 0.5f);              // 正午白
        colorKeys[2] = new GradientColorKey(new Color(1, 0.6f, 0.4f), 1.0f); // 日落橙
        sunColorGradient.colorKeys = colorKeys;
    }
}