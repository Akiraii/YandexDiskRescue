namespace YandexDiskRescue.Models;

public sealed class BackupJob
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Source { get; set; } = "ydr:";
    public string Destination { get; set; } = "";
    public int Transfers { get; set; } = 8;
    public bool Verify { get; set; } = true;
    public bool RecurringDaily { get; set; }
    public int DailyMinuteOfDay { get; set; } = 9 * 60;
    public int LimitKiBPerSecond { get; set; } = 0; // 0 = unlimited
    public DateTime? NotBeforeUtc { get; set; }
    public int RetryCount { get; set; }
    public DateTime? NextAttemptUtc { get; set; }
    public string Kind { get; set; } = "Копирование";
    public string? ReportPath { get; set; }
    public string? VolumeSerial { get; set; } // destination identity; never silently use a different disk
    public string? UnlimitedManifestPath { get; set; } // immutable snapshot of moved files
    public string State { get; set; } = "Ожидает";
    public string Details { get; set; } = "";
    public DateTime CreatedUtc { get; set; } = DateTime.UtcNow;
    public DateTime? FinishedUtc { get; set; }
    public override string ToString() => $"{State} | {Source} → {Destination} | {CreatedUtc.ToLocalTime():dd.MM HH:mm}";
}
