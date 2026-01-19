using UnityEngine;

public class ConstantSmoothRotation : MonoBehaviour
{
    [Header("设置")]
    public float rotationSpeed = 50f; // 恒定的旋转速度
    public float turbulence = 0.5f;   // 方向变化的频率（越小越平滑）

    private float timeX;
    private float timeY;
    private float timeZ;

    void Start()
    {
        // 给每个轴一个随机的噪声起点，防止同步
        timeX = Random.value * 100;
        timeY = Random.value * 100;
        timeZ = Random.value * 100;
    }

    void Update()
    {
        // 使用柏林噪声获取平滑变化的数值 (-1 到 1)
        // 柏林噪声的特点是连续，不会产生突变
        float nx = Mathf.PerlinNoise(Time.time * turbulence, timeX) * 2 - 1;
        float ny = Mathf.PerlinNoise(Time.time * turbulence, timeY) * 2 - 1;
        float nz = Mathf.PerlinNoise(Time.time * turbulence, timeZ) * 2 - 1;

        Vector3 driftAxis = new Vector3(nx, ny, nz);

        // 核心：绕着这个平滑变化的轴，以恒定速度旋转
        // 这样旋转速度始终由 rotationSpeed 决定，但轴向在慢慢漂移
        transform.Rotate(driftAxis.normalized, rotationSpeed * Time.deltaTime, Space.Self);
    }
}