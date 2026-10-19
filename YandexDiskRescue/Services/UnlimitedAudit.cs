using System.Text;
using System.Text.Json;
using YandexDiskRescue.Models;

namespace YandexDiskRescue.Services;

public sealed class UnlimitedSnapshot
{
    public DateTime CreatedUtc { get; set; } = DateTime.UtcNow;
    public int Expected { get; set; }
    public List<string> Listed { get; set; } = new();
    public List<string> Moved { get; set; } = new();
}

public sealed record UnlimitedSummary(int Expected, int Listed, int Moved, int Verified,
    int Missing, int Different, int NotMoved, int Uncertain, string CsvPath);

/// <summary>Never equates 'moved' with 'saved'. Counts verified paths using rclone --combined.</summary>
public static class UnlimitedAudit
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };
    public static string CaptureSnapshot()
    {
        var (listed, expected, moved) = UnlimitedPhotos.ReadState();
        if (expected != listed || listed == 0)
            throw new InvalidOperationException($"Список безлимита неполный: найдено {listed}, ожидалось {expected}. Скачивание можно запустить отдельно, но полный архив не подтверждён");
        var listPath = Path.Combine(UnlimitedPhotos.StateFolder, "unlim_list.json");
        using var doc = JsonDocument.Parse(File.ReadAllText(listPath));
        var items = doc.RootElement.GetProperty("items").EnumerateArray().Select(x => x.GetString()!).ToList();
        var completed = UnlimitedPhotos.ReadMovedSet();
        var snapshot = new UnlimitedSnapshot { Expected = expected, Listed = items, Moved = items.Where(completed.Contains).ToList() };
        if (snapshot.Moved.Count == 0) throw new InvalidOperationException("Нет подтверждённых переносов");
        string folder = Path.Combine(JobStore.Root, "data", "manifests");
        Directory.CreateDirectory(folder);
        string file = Path.Combine(folder, Guid.NewGuid().ToString("N") + ".json");
        File.WriteAllText(file, JsonSerializer.Serialize(snapshot, JsonOptions), new UTF8Encoding(false));
        return file;
    }

    // Explicit path validation also keeps state files from being used to escape local destinations.
    private static string Normalize(string source)
    {
        const string prefix = "/photounlim/";
        if (!source.StartsWith(prefix, StringComparison.Ordinal))
            throw new InvalidDataException("Unexpected photo path in snapshot");
        string rel = source[prefix.Length..].Replace('\\', '/');
        if (rel.Length == 0 || rel.StartsWith('/') || rel.Any(char.IsControl)
            || rel.Split('/').Any(x => x is "" or "." or ".."))
            throw new InvalidDataException("Unsafe path in unlimited snapshot");
        return rel;
    }
    public static UnlimitedSummary Export(BackupJob job)
    {
        if (string.IsNullOrWhiteSpace(job.UnlimitedManifestPath))
            throw new InvalidOperationException("Нет зафиксированного списка фотографий");
        var snapshot = JsonSerializer.Deserialize<UnlimitedSnapshot>(File.ReadAllText(job.UnlimitedManifestPath))
            ?? throw new InvalidDataException("Манифест пуст");
        var statuses = new Dictionary<string, char>(StringComparer.Ordinal);
        string combined = VerificationReport.RawPath(job.Id);
        if (File.Exists(combined)) foreach (string line in File.ReadLines(combined))
        {
            if (line.Length >= 3 && line[1] == ' ') statuses[line[2..].Replace('\\', '/')] = line[0];
        }
        var moved = snapshot.Moved.ToHashSet(StringComparer.Ordinal);
        int verified = 0, missing = 0, diff = 0, notMoved = 0, uncertain = 0;
        var output = new List<(string status, string src)>();
        foreach (var src in snapshot.Listed)
        {
            string rel = Normalize(src);
            string status;
            if (!moved.Contains(src)) { status = "Не перенесено из безлимита"; notMoved++; }
            else if (statuses.TryGetValue(rel, out char c) && c == '=') { status = "Проверено содержимое"; verified++; }
            else if (statuses.TryGetValue(rel, out c) && c == '+') { status = "Нет локальной копии"; missing++; }
            else if (statuses.TryGetValue(rel, out c) && c == '*') { status = "Различается"; diff++; }
            else { status = "Не подтверждено проверкой"; uncertain++; }
            output.Add((status, src));
        }
        Directory.CreateDirectory(VerificationReport.ReportRoot);
        var path = Path.Combine(VerificationReport.ReportRoot, job.Id.ToString("N") + "-photos.csv");
        using var w = new StreamWriter(path, false, new UTF8Encoding(true));
        w.WriteLine("Статус;Облачный путь");
        static string Esc(string v) => "\"" + v.Replace("\"", "\"\"") + "\"";
        foreach (var item in output) w.WriteLine(Esc(item.status) + ";" + Esc(item.src));
        return new UnlimitedSummary(snapshot.Expected, snapshot.Listed.Count, snapshot.Moved.Count,
            verified, missing, diff, notMoved, uncertain, path);
    }
}
