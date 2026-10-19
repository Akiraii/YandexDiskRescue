using System.Globalization;
using System.Net;
using System.Text;
using YandexDiskRescue.Models;

namespace YandexDiskRescue.Services;

/// <summary>Turns rclone --combined status into locally stored, reviewable reports.</summary>
public static class VerificationReport
{
    public static string ReportRoot => Path.Combine(JobStore.Root, "reports");
    public static string RawPath(Guid id) => Path.Combine(ReportRoot, id.ToString("N") + ".combined.txt");
    private static readonly Dictionary<char,string> Labels = new()
    {
        ['=']="Совпадает", ['+']="Нет в назначении", ['-']="Нет в источнике",
        ['*']="Различается", ['!']="Ошибка проверки", ['?']="Неизвестно"
    };
    public static (string csv, string html, Dictionary<string,int> counts) Export(BackupJob job, int exitCode)
    {
        Directory.CreateDirectory(ReportRoot);
        var rows = new List<(string status,string path)>();
        var raw = RawPath(job.Id);
        if (File.Exists(raw))
        {
            foreach (var line in File.ReadLines(raw))
            {
                if (line.Length < 2 || line[1] != ' ') continue;
                rows.Add((Labels.GetValueOrDefault(line[0], "Неизвестно ("+line[0]+")"),line[2..]));
            }
        }
        var counts=rows.GroupBy(x=>x.status).ToDictionary(x=>x.Key,x=>x.Count());
        string prefix=Path.Combine(ReportRoot, job.Id.ToString("N"));
        string csv=prefix+".csv",html=prefix+".html";
        static string Csv(string v)=>"\""+v.Replace("\"","\"\"")+"\"";
        using(var writer=new StreamWriter(csv,false,new UTF8Encoding(true)))
        {
            writer.WriteLine("Статус;Путь");
            foreach(var (status,path) in rows) writer.WriteLine(Csv(status)+";"+Csv(path));
        }
        static string H(string s)=>WebUtility.HtmlEncode(s);
        var sb=new StringBuilder("<!doctype html><html lang=\"ru\"><head><meta charset=\"utf-8\"><title>Yandex Disk Rescue — проверка</title><style>body{font:15px system-ui;margin:32px;background:#111827;color:#e5e7eb}table{border-collapse:collapse;width:100%}td,th{padding:8px;border-bottom:1px solid #374151;text-align:left;overflow-wrap:anywhere}small{color:#9ca3af}</style></head><body>");
        sb.Append("<h1>Проверка резервной копии</h1><p>Источник: ").Append(H(job.Source)).Append("</p><p>Назначение: ").Append(H(job.Destination)).Append("</p><p>Дата UTC: ").Append(H(DateTime.UtcNow.ToString("O",CultureInfo.InvariantCulture))).Append("</p><p>Код rclone check: ").Append(exitCode).Append("</p>");
        foreach(var c in counts) sb.Append("<p>").Append(H(c.Key)).Append(": ").Append(c.Value).Append("</p>");
        sb.Append("<p><small>Статусы получены из rclone check --combined. Успешная проверка хешей зависит от поддержки хеширования удалённым хранилищем. Для полной сверки содержимого требуется режим --download.</small></p><table><thead><tr><th>Статус</th><th>Путь</th></tr></thead><tbody>");
        foreach(var (status,path) in rows) sb.Append("<tr><td>").Append(H(status)).Append("</td><td>").Append(H(path)).Append("</td></tr>");
        sb.Append("</tbody></table></body></html>");
        File.WriteAllText(html,sb.ToString(),new UTF8Encoding(false));
        return(csv,html,counts);
    }
}
