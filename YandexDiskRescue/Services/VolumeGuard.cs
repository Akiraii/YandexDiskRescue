using System.ComponentModel;
using System.Runtime.InteropServices;

namespace YandexDiskRescue.Services;

/// <summary>Detects removable disk letter reuse, e.g. E: mounted as a different disk.</summary>
public static class VolumeGuard
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetVolumeInformationW(string root, System.Text.StringBuilder? volumeName,
        uint volumeNameSize, out uint serial, out uint maxComponent, out uint fileSystemFlags,
        System.Text.StringBuilder? fileSystemName, uint fileSystemNameSize);

    public static string Capture(string destination)
    {
        if (!Path.IsPathFullyQualified(destination)) throw new ArgumentException("Нужен абсолютный путь назначения");
        string full = Path.GetFullPath(destination);
        string root = Path.GetPathRoot(full) ?? throw new IOException("Не определён том назначения");
        if (root.StartsWith("\\\\", StringComparison.Ordinal))
            throw new NotSupportedException("Для надёжной проверки тома выберите локальный или USB-диск, не сетевую папку");
        if (!Directory.Exists(root)) throw new IOException("Диск назначения сейчас недоступен");
        if (!GetVolumeInformationW(root, null, 0, out uint serial, out _, out _, null, 0))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Не удалось получить серийный номер тома");
        return serial.ToString("X8");
    }

    public static void Verify(string destination, string? expectedSerial)
    {
        if (string.IsNullOrWhiteSpace(expectedSerial))
            throw new IOException("Нет привязки к тому. В интерфейсе повторно поставьте задание в очередь с подтверждённым диском");
        string actual = Capture(destination);
        if (!string.Equals(actual, expectedSerial, StringComparison.OrdinalIgnoreCase))
            throw new IOException($"Подключён другой диск (ожидался том {expectedSerial}, обнаружен {actual}). Запись заблокирована");
    }
}
