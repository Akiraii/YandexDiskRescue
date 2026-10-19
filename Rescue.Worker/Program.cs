using YandexDiskRescue.Services;
using YandexDiskRescue.Models;

using var singleton = new Mutex(true, @"Local\YDR_Worker_" + Environment.UserName.Replace(' ', '_'), out bool created);
if (!created) return;
var store = new JobStore();
string logPath = Path.Combine(JobStore.Root, "log", "worker.log");
Directory.CreateDirectory(Path.GetDirectoryName(logPath)!);
var logGate=new object();
void Log(string msg)
{
    lock(logGate)
    {
        try
        {
            // Rotate at 10 MiB; never put user data in external telemetry.
            if(File.Exists(logPath) && new FileInfo(logPath).Length>10*1024*1024)
            {
                for(int i=2;i>=1;i--)
                {
                    string old=logPath+"."+i, next=logPath+"."+(i+1);
                    if(File.Exists(old))File.Move(old,next,true);
                }
                File.Move(logPath,logPath+".1",true);
            }
            File.AppendAllText(logPath, DateTime.Now.ToString("O") + " " + msg + Environment.NewLine);
        }
        catch { /* log failures cannot terminate jobs */ }
    }
}
void State(Guid id, string state, string details = "") => store.Change(all =>
{
    var j=all.FirstOrDefault(x=>x.Id==id);
    if(j is null)return;
    bool newlyComplete=state=="Завершено" && j.State!="Завершено";
    j.State=state; j.Details=details;
    if(state is "Завершено" or "Ошибка" or "Неполный архив" or "Ошибка проверки") j.FinishedUtc=DateTime.UtcNow;
    if(newlyComplete && j.RecurringDaily && j.UnlimitedManifestPath is null)
    {
        var local=DateTime.Today.AddDays(1).AddMinutes(Math.Clamp(j.DailyMinuteOfDay,0,1439));
        all.Add(new BackupJob {
            Source=j.Source,Destination=j.Destination,VolumeSerial=j.VolumeSerial,
            Transfers=j.Transfers,Verify=j.Verify,LimitKiBPerSecond=j.LimitKiBPerSecond,
            RecurringDaily=true,DailyMinuteOfDay=j.DailyMinuteOfDay,
            NotBeforeUtc=DateTime.SpecifyKind(local,DateTimeKind.Local).ToUniversalTime()
        });
    }
});
void Retry(Guid id, string problem)
{
    store.Change(all =>
    {
        var j=all.FirstOrDefault(x=>x.Id==id);
        if(j is null)return;
        j.RetryCount++;
        if(j.RetryCount>=5)
        {
            j.State="Ошибка"; j.Details="После 5 попыток: " + problem; j.FinishedUtc=DateTime.UtcNow;
        }
        else
        {
            j.NextAttemptUtc=DateTime.UtcNow.AddMinutes(Math.Min(60,Math.Pow(2,j.RetryCount)));
            j.State="Ожидает"; j.Details=$"Попытка {j.RetryCount}/5 после {j.NextAttemptUtc.Value.ToLocalTime():g}: {problem}";
        }
    });
}
// A crash during copy does NOT mean the files were saved; replay the job idempotently.
store.Change(all => { foreach(var j in all.Where(x=>x.State is "Копирование" or "Проверка"))
    { j.State="Ожидает";j.Details="Повторная сверка после аварийного завершения"; } });
using var cts = new CancellationTokenSource();
Console.CancelKeyPress += (_,e) => {e.Cancel=true;cts.Cancel();};
while(!cts.IsCancellationRequested)
{
    BackupJob? job;
    try
    {
        job=store.Load().FirstOrDefault(j => j.State=="Ожидает"
          && (!j.NotBeforeUtc.HasValue || j.NotBeforeUtc.Value<=DateTime.UtcNow)
          && (!j.NextAttemptUtc.HasValue || j.NextAttemptUtc.Value<=DateTime.UtcNow));
    }
    catch(Exception e) {Log("Не удалось загрузить очередь: "+e.Message); try{await Task.Delay(4000,cts.Token);}catch(OperationCanceledException){} continue;}
    if(job is null) {try{await Task.Delay(2000,cts.Token);}catch(OperationCanceledException){} continue;}
    using var jobCts=CancellationTokenSource.CreateLinkedTokenSource(cts.Token);
    using var watchStop=new CancellationTokenSource();
    var watch=Task.Run(async () =>
    {
        while(!watchStop.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(1000,watchStop.Token);
                var status=store.Load().FirstOrDefault(x=>x.Id==job.Id)?.State;
                if(status is "Приостановлено" or "Отменено") {jobCts.Cancel();return;}
            }
            catch(OperationCanceledException) {break;}
            catch(Exception e) {Log("Ошибка наблюдения за заданием: "+e.Message);}
        }
    });
    try
    {
        string? token=SecureTokenStore.Read();
        if(string.IsNullOrWhiteSpace(token))
        {
            State(job.Id,"Нужна авторизация","В приложении разрешите хранение токена для фоновой работы");
            continue;
        }
        string dest=Path.GetFullPath(job.Destination);
        VolumeGuard.Verify(dest,job.VolumeSerial); // BEFORE creating or writing files
        Directory.CreateDirectory(dest);
        using var rclone=new RcloneSession(token);
        int copyCode=0;
        if(job.Kind!="Проверка")
        {
            State(job.Id,"Копирование");
            copyCode=await rclone.RunAsync("copy",new[]{job.Source,dest,
                "--transfers",Math.Clamp(job.Transfers,1,32).ToString(),
                "--bwlimit",job.LimitKiBPerSecond>0?$"{job.LimitKiBPerSecond}k":"off",
                "--checkers","8","--immutable","--retries","2","--low-level-retries","2",
                "--timeout","60s","--stats","10s"},Log,jobCts.Token);
        }
        if(job.Verify || job.Kind=="Проверка" || job.UnlimitedManifestPath is not null)
        {
            Directory.CreateDirectory(VerificationReport.ReportRoot);
            var combined=VerificationReport.RawPath(job.Id);
            if(File.Exists(combined))File.Delete(combined); // avoid stale success on failed check
            State(job.Id,"Проверка");
            var checkArgs=new List<string>{job.Source,dest,"--one-way","--combined",combined};
            if(job.UnlimitedManifestPath is not null)checkArgs.Add("--download"); // actually compare file contents
            int verifyCode=await rclone.RunAsync("check",checkArgs,Log,jobCts.Token);
            var output=VerificationReport.Export(job,verifyCode);
            string status=copyCode==0 && verifyCode==0 ? "Завершено" : "Ошибка проверки";
            string details=$"Копирование {copyCode}, проверка {verifyCode}; HTML: {output.html}";
            if(job.UnlimitedManifestPath is not null)
            {
                var summary=UnlimitedAudit.Export(job);
                details+=$"; проверено {summary.Verified}/{summary.Expected}; не перенесено {summary.NotMoved}; отсутствует {summary.Missing}; различается {summary.Different}; неопределённо {summary.Uncertain}; CSV: {summary.CsvPath}";
                if(summary.Verified!=summary.Expected) status="Неполный архив";
            }
            store.Change(all => {var stored=all.FirstOrDefault(x=>x.Id==job.Id);
                if(stored is not null)stored.ReportPath=output.html;});
            if(status=="Завершено")State(job.Id,status,details);
            else if(job.UnlimitedManifestPath is not null)
            {
                // Never claim full success. Partial result remains visible in local reports.
                State(job.Id,"Неполный архив",details);
            }
            else Retry(job.Id,details);
        }
        else if(copyCode==0)State(job.Id,"Завершено","Копирование закончено без проверки (не рекомендуется)");
        else Retry(job.Id,$"rclone copy: код {copyCode}");
    }
    catch(OperationCanceledException)
    {
        string? current=store.Load().FirstOrDefault(x=>x.Id==job.Id)?.State;
        if(current is not ("Приостановлено" or "Отменено"))
            State(job.Id,"Ожидает","Прервано: потребуется сверка");
        if(cts.IsCancellationRequested) break;
    }
    catch(IOException e) when (e.Message.Contains("диск",StringComparison.OrdinalIgnoreCase) || e.Message.Contains("том",StringComparison.OrdinalIgnoreCase))
    {
        store.Change(all=> {var item=all.FirstOrDefault(x=>x.Id==job.Id);if(item is not null) {
            item.State="Ожидает";item.Details="Ожидание правильного диска: "+e.Message;
            item.NextAttemptUtc=DateTime.UtcNow.AddMinutes(1);}});
        Log("Диск отсутствует или заменён: "+e.Message);
    }
    catch(Exception e) {Log("Сбой задания "+job.Id+": "+e.GetType().Name+" / "+e.Message);Retry(job.Id,e.Message);}
    finally
    {
        watchStop.Cancel();
        try {await watch;} catch(OperationCanceledException){}
    }
}
