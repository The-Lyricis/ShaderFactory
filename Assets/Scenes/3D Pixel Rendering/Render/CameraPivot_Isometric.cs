using UnityEngine;

public class CameraPivot_Isometric : MonoBehaviour
{
    public float targetAngle = 45f;
    public float mouseSensitivity = 2f;
    public float rotationSpeed = 5f;

    void Update()
    {
        float mouseX = Input.GetAxis("Mouse X");

        if (Input.GetMouseButton(0))
        {
            targetAngle += mouseX * mouseSensitivity;
        }
        else
        {
            int step = Mathf.RoundToInt(targetAngle / 45f);
            targetAngle = step * 45f;
        }

        if (targetAngle < 0f) targetAngle += 360f;
        if (targetAngle > 360f) targetAngle -= 360f;

        float currentAngle = Mathf.LerpAngle(transform.eulerAngles.y, targetAngle, rotationSpeed * Time.deltaTime);
        transform.rotation = Quaternion.Euler(30f, currentAngle, 0f);
    }
}
