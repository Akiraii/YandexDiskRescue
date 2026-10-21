using System.Diagnostics;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Security.Cryptography;
using System.Text;

namespace YandexDiskRescue.Services;

/// <summary>Explicitly opt-in integration with upstream yd.js; list is read-only, move requires GUI confirmation.</summary>
public static class UnlimitedPhotos
{
    public static readonly string StateFolder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "YandexDiskRescue", "unlimited-state");
    private sealed record ChromeLaunch(int Pid, DateTime StartUtc);
    private static string Profile => Path.Combine(JobStore.Root, "chrome-unlimited-profile");
    private static string ChromeMeta => Path.Combine(JobStore.Root, "config", "chrome-launch.json");
    public sealed record Quota(long UnlimitedBytes, long FreeBytes, string AccountUid)
    {
        public bool EnoughForMove => UnlimitedBytes > 0 && FreeBytes >= UnlimitedBytes + UnlimitedBytes / 20;
        public override string ToString() => $"Безлимит: {ToSize(UnlimitedBytes)}; свободно: {ToSize(FreeBytes)}. " +
            (EnoughForMove ? "Есть запас 5% для переноса." : "Недостаточно места или объём не обнаружен: перенос заблокирован.");
    }
    private static string ToSize(long bytes) => $"{bytes / 1073741824d:0.00} ГиБ";
    public static async Task<Quota> GetQuotaAsync(string token, CancellationToken ct)
    {
        using var client = new HttpClient { Timeout=TimeSpan.FromSeconds(25) };
        using var request = new HttpRequestMessage(HttpMethod.Get, "https://cloud-api.yandex.net/v1/disk/?fields=photounlim_size,total_space,used_space,user.uid");
        request.Headers.Authorization = new AuthenticationHeaderValue("OAuth", token);
        using var response = await client.SendAsync(request, ct);
        response.EnsureSuccessStatusCode();
        using var json = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(ct));
        var obj=json.RootElement;
        long v(string key) => obj.TryGetProperty(key,out var field) && field.ValueKind==JsonValueKind.Number ? field.GetInt64() : 0;
        var unlimited=v("photounlim_size");var free=Math.Max(0,v("total_space")-v("used_space"));
        string uid="";
        if(obj.TryGetProperty("user",out var user) && user.ValueKind==JsonValueKind.Object
            && user.TryGetProperty("uid",out var id)) uid=id.ToString();
        if(!System.Text.RegularExpressions.Regex.IsMatch(uid,@"^\d+$"))
            throw new InvalidDataException("API не вернул идентификатор аккаунта: безопасная проверка входа невозможна");
        return new Quota(unlimited,free,uid);
    }
    // Chrome chooses an unpredictable local port; never expose its debugging socket publicly.
    // Called only AFTER the user explicitly approved modifying cloud photo locations.
    public static async Task EnsureCloudFolderAsync(string token, CancellationToken ct)
    {
        string url="https://cloud-api.yandex.net/v1/disk/resources?path="
            +Uri.EscapeDataString("disk:/Безлимит")+"&fields=type";
        using var client=new HttpClient {Timeout=TimeSpan.FromSeconds(25)};
        using var request=new HttpRequestMessage(HttpMethod.Get,url);
        request.Headers.Authorization=new AuthenticationHeaderValue("OAuth",token);
        using var existing=await client.SendAsync(request,ct);
        if(existing.IsSuccessStatusCode)
        {
            using var obj=JsonDocument.Parse(await existing.Content.ReadAsStreamAsync(ct));
            if(!obj.RootElement.TryGetProperty("type",out var type) || type.GetString()!="dir")
                throw new InvalidOperationException("Путь «Безлимит» занят не папкой. Перенос заблокирован");
            return;
        }
        if(existing.StatusCode!=System.Net.HttpStatusCode.NotFound)
            throw new HttpRequestException("Не удалось проверить облачную папку: HTTP "+(int)existing.StatusCode);
        using var create=new HttpRequestMessage(HttpMethod.Put,url);
        create.Headers.Authorization=new AuthenticationHeaderValue("OAuth",token);
        using var result=await client.SendAsync(create,ct);
        if(!result.IsSuccessStatusCode && result.StatusCode!=System.Net.HttpStatusCode.Conflict)
            throw new HttpRequestException("Не удалось создать папку «Безлимит»: HTTP "+(int)result.StatusCode);
        // Verify the folder after creation or a concurrent creation, not just the HTTP status.
        using var verify=new HttpRequestMessage(HttpMethod.Get,url);
        verify.Headers.Authorization=new AuthenticationHeaderValue("OAuth",token);
        using var check=await client.SendAsync(verify,ct);
        check.EnsureSuccessStatusCode();
        using var doc=JsonDocument.Parse(await check.Content.ReadAsStreamAsync(ct));
        if(doc.RootElement.GetProperty("type").GetString()!="dir")
            throw new InvalidDataException("Облачный путь назначения не является папкой");
    }
    public static void StartIsolatedChrome()
    {
        string[] paths = {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),"Google","Chrome","Application","chrome.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),"Google","Chrome","Application","chrome.exe")
        };
        var exe = paths.FirstOrDefault(File.Exists) ?? throw new FileNotFoundException("Chrome не найден");
        try
        {
            var existing=Endpoint();
            throw new InvalidOperationException("Окно браузера для спасения уже открыто. Используйте его ("+existing+")");
        }
        catch (InvalidOperationException ex) when(!ex.Message.StartsWith("Окно браузера для спасения",StringComparison.Ordinal))
        { /* prior session is no longer alive */ }
        catch (FileNotFoundException) { /* first session */ }
        catch (ArgumentException) { /* old Chrome pid */ }
        Directory.CreateDirectory(Profile);
        var acl = new DirectorySecurity(); acl.SetAccessRuleProtection(true, false);
        var sid = WindowsIdentity.GetCurrent().User ?? throw new InvalidOperationException("Не найден SID пользователя");
        acl.AddAccessRule(new FileSystemAccessRule(sid,FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,PropagationFlags.None,AccessControlType.Allow));
        new DirectoryInfo(Profile).SetAccessControl(acl);
        var start = new ProcessStartInfo(exe) { UseShellExecute=false };
        start.ArgumentList.Add("--remote-debugging-address=127.0.0.1");
        start.ArgumentList.Add("--remote-debugging-port=0"); // ephemeral port assigned by Chrome
        start.ArgumentList.Add("--disable-sync");
        start.ArgumentList.Add("--disable-extensions");
        start.ArgumentList.Add("--no-first-run");
        start.ArgumentList.Add("--user-data-dir=" + Profile);
        start.ArgumentList.Add("https://disk.yandex.ru/client/photo");
        string stale=Path.Combine(Profile,"DevToolsActivePort");
        if(File.Exists(stale)) File.Delete(stale);
        var process = Process.Start(start) ?? throw new InvalidOperationException("Chrome не запущен");
        Directory.CreateDirectory(Path.GetDirectoryName(ChromeMeta)!);
        File.WriteAllText(ChromeMeta, JsonSerializer.Serialize(new ChromeLaunch(process.Id, process.StartTime.ToUniversalTime())));
    }
    private static string Endpoint()
    {
        if (!File.Exists(ChromeMeta)) throw new InvalidOperationException("Сначала откройте Chrome кнопкой приложения");
        var launch=JsonSerializer.Deserialize<ChromeLaunch>(File.ReadAllText(ChromeMeta))
            ?? throw new InvalidDataException("Недействительные данные профиля Chrome");
        using var p=Process.GetProcessById(launch.Pid);
        if(p.HasExited || Math.Abs((p.StartTime.ToUniversalTime() - launch.StartUtc).TotalSeconds)>5)
            throw new InvalidOperationException("Сессия Chrome больше не активна. Откройте новый Chrome");
        string portFile=Path.Combine(Profile,"DevToolsActivePort");
        if(!File.Exists(portFile)) throw new InvalidOperationException("Chrome ещё не открыл отладочный порт. Повторите действие через несколько секунд");
        string portText=File.ReadLines(portFile).FirstOrDefault() ?? "";
        if(!int.TryParse(portText,out int port) || port < 1024 || port > 65535)
            throw new InvalidDataException("Неверный отладочный порт Chrome");
        return "http://127.0.0.1:"+port;
    }
    public static void ClearIsolatedProfile()
    {
        if(File.Exists(ChromeMeta))
        {
            try {
                var meta=JsonSerializer.Deserialize<ChromeLaunch>(File.ReadAllText(ChromeMeta));
                if(meta!=null) {using var p=Process.GetProcessById(meta.Pid);
                    if(!p.HasExited && Math.Abs((p.StartTime.ToUniversalTime()-meta.StartUtc).TotalSeconds)<5)
                        throw new InvalidOperationException("Сначала закройте отдельное окно Chrome");}
            } catch (ArgumentException) { /* process no longer exists */ }
        }
        if(Directory.Exists(Profile)) Directory.Delete(Profile,true);
        if(File.Exists(ChromeMeta)) File.Delete(ChromeMeta);
    }
    public static HashSet<string> ReadMovedSet()
    {
        var done = new HashSet<string>(StringComparer.Ordinal);
        var moved = Path.Combine(StateFolder,"moved.jsonl");
        if (File.Exists(moved)) foreach(var line in File.ReadLines(moved))
        {
            if(string.IsNullOrWhiteSpace(line)) continue;
            try
            {
                using var entry=JsonDocument.Parse(line);
                if(entry.RootElement.TryGetProperty("ok",out var ok) && ok.ValueKind==JsonValueKind.True
                    && entry.RootElement.TryGetProperty("src",out var src) && src.ValueKind==JsonValueKind.String)
                    done.Add(src.GetString()!);
            }
            catch(JsonException) { /* interrupted append is not a successful transfer */ }
        }
        return done;
    }
    public static (int Listed, int Expected, int Moved) ReadState()
    {
        var list = Path.Combine(StateFolder,"unlim_list.json");
        if (!File.Exists(list)) throw new FileNotFoundException("Сначала соберите список фотографий");
        using var doc=JsonDocument.Parse(File.ReadAllText(list));
        var root=doc.RootElement;
        var listedItems=root.GetProperty("items").EnumerateArray().Select(x=>x.GetString()!).ToList();
        var expected=root.GetProperty("expected").GetInt32();
        if (listedItems.Count==0 || expected<=0 || listedItems.Count!=listedItems.Distinct(StringComparer.Ordinal).Count())
            throw new InvalidDataException("Список фотографий пуст, неверен или содержит дубликаты");
        var done=ReadMovedSet();
        return (listedItems.Count, expected, listedItems.Count(done.Contains));
    }
    public static async Task<int> RunScriptAsync(string script, string action, string expectedUid, Action<string> log, CancellationToken token)
    {
        if (action is not ("list" or "move")) throw new ArgumentException("Недопустимая операция");
        string shipped=Path.GetFullPath(Path.Combine(AppContext.BaseDirectory,"tools","yd.js"));
        if (!File.Exists(script) || !string.Equals(Path.GetFullPath(script),shipped,StringComparison.OrdinalIgnoreCase))
            throw new FileNotFoundException("Для безопасности разрешён только встроенный tools/yd.js");
        using (var input=File.OpenRead(shipped))
        {
            string actual=Convert.ToHexString(SHA256.HashData(input));
            if(!string.Equals(actual,"F3A5EABC666F2A75B1A637A319F647A87B2201DAD3CF3650EF532A054BBABBD4",StringComparison.Ordinal))
                throw new InvalidDataException("Контрольная сумма помощника yd.js изменилась. Выполнение заблокировано");
        }
        var state=StateFolder;
        Directory.CreateDirectory(state);
        string node=Path.Combine(AppContext.BaseDirectory,"tools","node.exe");
        if (!File.Exists(node)) throw new FileNotFoundException("Отсутствует встроенный tools/node.exe. Выполнение браузерного помощника заблокировано.", node);
        var psi=new ProcessStartInfo(node) { UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true,WorkingDirectory=Path.GetDirectoryName(Path.GetFullPath(script))!,StandardOutputEncoding=System.Text.Encoding.UTF8,StandardErrorEncoding=System.Text.Encoding.UTF8 };
        if(!System.Text.RegularExpressions.Regex.IsMatch(expectedUid,@"^\d+$"))
            throw new InvalidOperationException("Не получен идентификатор аккаунта из API Яндекса");
        string endpoint="";
        for(int i=0;i<40;i++)
        {
            try {endpoint=Endpoint();break;}
            catch(InvalidOperationException) when(i<39) {await Task.Delay(250,token);}
        }
        psi.Environment["YD_CDP"] = endpoint;
        psi.Environment["YD_EXPECTED_UID"] = expectedUid;
        psi.ArgumentList.Add(Path.GetFullPath(script));psi.ArgumentList.Add(action);psi.ArgumentList.Add(state);
        if(action=="move") {psi.ArgumentList.Add("2147483647");psi.ArgumentList.Add("40");}
        // Only one script may mutate/read the mutable manifest at a time.
        // One browser session and one mutable state journal must never have concurrent writers.
        using var gate=new Mutex(false, @"Local\YDR_Unlimited_"+Environment.UserName.Replace(' ','_'));
        bool acquired=false;
        try { try {acquired=gate.WaitOne(TimeSpan.FromSeconds(2));}catch(AbandonedMutexException){acquired=true;}
            if(!acquired)throw new InvalidOperationException("Уже выполняется другая операция безлимита"); }
        catch { if(acquired)gate.ReleaseMutex();throw; }
        // The full Windows package includes node.exe and pinned Playwright; no npm runs on end-user PCs.
        Process? process=null;
        try { process = Process.Start(psi) ?? throw new InvalidOperationException("Не удалось запустить Node.js"); }
        catch {gate.ReleaseMutex();throw;}
        using var ownedProcess=process;
        async Task Read(StreamReader reader)
        {
            while (await reader.ReadLineAsync(token) is { } line) log(LogRedactor.Redact(line));
        }
        try
        {
            try { await Task.WhenAll(Read(process.StandardOutput),Read(process.StandardError),process.WaitForExitAsync(token)); }
            catch(OperationCanceledException) {if(!process.HasExited)process.Kill(entireProcessTree:true);await process.WaitForExitAsync(CancellationToken.None);throw;}
            return process.ExitCode;
        }
        finally {gate.ReleaseMutex();}
    }
}
