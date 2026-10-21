using System.Text.RegularExpressions;

namespace YandexDiskRescue.Services;

/// <summary>
/// Reduces accidental credentials leakage from rclone, Node, or HTTP exception logs.
/// It is not a security boundary against code running as the same Windows user.
/// </summary>
public static class LogRedactor
{
    private static readonly Regex CredentialFields = new(
        @"(?i)(\b(?:access_token|refresh_token|authorization|oauth_token|client_secret|session_key|sk)\b\s*[:=]\s*[""']?)([^\s,;""'&}]+)",
        RegexOptions.Compiled | RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(250));
    private static readonly Regex UrlSecrets = new(
        @"(?i)([?&](?:token|access_token|oauth_token|signature|sig|auth|sk|key)=)[^&#\s]+",
        RegexOptions.Compiled | RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(250));
    public static string Redact(string? line, string? oauth = null)
    {
        if (string.IsNullOrEmpty(line)) return string.Empty;
        string safe = !string.IsNullOrEmpty(oauth) ? line.Replace(oauth,"[REDACTED]",StringComparison.Ordinal) : line;
        try
        {
            safe=CredentialFields.Replace(safe, "$1[REDACTED]");
            safe=UrlSecrets.Replace(safe, "$1[REDACTED]");
        }
        catch (RegexMatchTimeoutException) { return "[REDACTED: oversized log line]"; }
        return safe;
    }
}
