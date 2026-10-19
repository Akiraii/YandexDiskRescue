using Microsoft.Win32;

namespace YandexDiskRescue.Services;

/// <summary>Starts a non-elevated per-user worker after Windows logon; no system service or passwords.</summary>
public static class StartupRegistration
{
    private const string AppName = "YandexDiskRescue.Worker";
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    public static bool Enabled
    {
        get { using var key = Registry.CurrentUser.OpenSubKey(RunKey); return key?.GetValue(AppName) is string; }
    }
    public static void Set(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey, writable: true)
            ?? throw new InvalidOperationException("Невозможно открыть ключ автозапуска текущего пользователя");
        if (!enabled) { key.DeleteValue(AppName, false); return; }
        var worker = Path.Combine(AppContext.BaseDirectory, "Rescue.Worker.exe");
        if (!File.Exists(worker)) throw new FileNotFoundException("Не найден Rescue.Worker.exe", worker);
        key.SetValue(AppName, "\"" + worker + "\"", RegistryValueKind.String);
    }
}
