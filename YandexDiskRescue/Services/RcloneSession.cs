using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace YandexDiskRescue.Services;

/// <summary>
/// Rclone runs with an in-memory remote using per-child environment variables.
/// No plaintext OAuth configuration file is ever created on disk.
/// </summary>
public sealed class RcloneSession : IDisposable
{
    private readonly string _tokenJson;
    private readonly string _executable;
    public RcloneSession(string token)
    {
        if (!System.Text.RegularExpressions.Regex.IsMatch(token,@"^[A-Za-z0-9_.-]{20,}$"))
            throw new ArgumentException("Некорректный формат OAuth-токена");
        _executable=ResolveExecutable();
        _tokenJson=JsonSerializer.Serialize(new {
            access_token=token,token_type="OAuth",refresh_token="unused",expiry="2099-01-01T00:00:00Z"
        });
    }
    private static string ResolveExecutable()
    {
        var bundled=Path.Combine(AppContext.BaseDirectory,"tools","rclone.exe");
        if(File.Exists(bundled))return bundled;
        string? path=Environment.GetEnvironmentVariable("PATH");
        foreach(var part in (path ?? "").Split(Path.PathSeparator))
        {
            try {var file=Path.Combine(part.Trim('"'),"rclone.exe");if(File.Exists(file))return file;}
            catch { /* invalid PATH segment */ }
        }
        throw new FileNotFoundException("Нет rclone.exe. Переустановите полный комплект приложения");
    }
    public async Task<int> RunAsync(string verb,IEnumerable<string> args,Action<string> output,CancellationToken ct)
    {
        if(verb is not ("about" or "lsf" or "copy" or "check"))
            throw new ArgumentException("Недопустимая операция");
        using var process=new Process();
        var psi=new ProcessStartInfo(_executable)
        {
            UseShellExecute=false, CreateNoWindow=true, RedirectStandardOutput=true,
            RedirectStandardError=true, StandardOutputEncoding=Encoding.UTF8, StandardErrorEncoding=Encoding.UTF8
        };
        // rclone's documented per-remote configuration environment variables.
        // The config file is in-memory only on Windows (NUL).
        psi.Environment["RCLONE_CONFIG_YDR_TYPE"]="yandex";
        psi.Environment["RCLONE_CONFIG_YDR_TOKEN"]=_tokenJson;
        psi.ArgumentList.Add("--config"); psi.ArgumentList.Add("NUL");
        psi.ArgumentList.Add(verb);
        foreach(var arg in args)psi.ArgumentList.Add(arg);
        process.StartInfo=psi;
        process.Start();
        async Task Drain(StreamReader reader)
        {
            while(await reader.ReadLineAsync(ct) is { } line)output(line);
        }
        try
        {
            await Task.WhenAll(Drain(process.StandardOutput),Drain(process.StandardError),process.WaitForExitAsync(ct));
        }
        catch(OperationCanceledException)
        {
            if(!process.HasExited)process.Kill(entireProcessTree:true);
            await process.WaitForExitAsync(CancellationToken.None);
            throw;
        }
        return process.ExitCode;
    }
    public void Dispose() { /* no temporary token files to clean up */ }
}
