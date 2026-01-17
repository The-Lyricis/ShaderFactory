using UnityEngine;

public class DayNightCycle : MonoBehaviour
{
    [Header("时间设置")]
    [Tooltip("完成一个昼夜循环所需的分钟数")]
    public float dayLengthInMinutes = 1.0f;
    
    [Range(0, 1)]
    [Tooltip("当前时间进度 (0 = 日出, 0.5 = 日落, 1 = 再次日出)")]
    public float timeOfDay = 0;

    [Header("光照强度设置")]
    public float maxIntensity = 1.2f;
    public float minIntensity = 0f;
    
    private Light sunLight;

    void Start()
    {
        sunLight = GetComponent<Light>();
    }

    void Update()
    {
        UpdateRotation();
        UpdateTime();
        UpdateIntensity();
    }

    // 更新旋转
    void UpdateRotation()
    {
        // 角度计算：timeOfDay 从 0 到 1 对应旋转 0 到 360 度
        // 我们通常给 X 轴一个起始偏转量，或者调整初始角度让 0 点对应日出
        float sunAngle = timeOfDay * 360f;
        
        // 旋转逻辑：绕 X 轴旋转（主旋转），Y 轴可以微调太阳的方向（例如东南升起）
        transform.localRotation = Quaternion.Euler(sunAngle, -90f, 0f);
    }

    // 更新时间进度
    void UpdateTime()
    {
        // 计算每秒增加的进度
        float timeDelta = Time.deltaTime / (dayLengthInMinutes * 60f);
        timeOfDay += timeDelta;

        // 循环时间
        if (timeOfDay >= 1)
        {
            timeOfDay = 0;
        }
    }

    // 根据太阳高度调整光照强度（可选）
    void UpdateIntensity()
    {
        if (sunLight == null) return;

        // 当太阳处于地平线以下时（180 到 360 度），强度设为 0
        if (timeOfDay > 0.5f)
        {
            sunLight.intensity = minIntensity;
        }
        else
        {
            // 简单的淡入淡出效果
            sunLight.intensity = maxIntensity;
        }
    }
}