#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$files=Get-ChildItem $root -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1') }
foreach($f in $files){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$tokens,[ref]$errors)
    if($errors.Count -gt 0){
        foreach($e in $errors){Write-Host "$($f.Name): $($e.Message) at $($e.Extent.StartLineNumber)"}
        throw "Parse errors in $($f.Name)"
    }
    Write-Host "[PASS] PowerShell AST: $($f.Name)"
}
[xml]$xaml=Get-Content (Join-Path $root 'MainWindow.xaml') -Raw -Encoding UTF8
$controls=[regex]::Matches($xaml.OuterXml,'x:Name="([^"]+)"')
foreach($m in $controls){if([string]::IsNullOrWhiteSpace($m.Groups[1].Value)){throw 'Empty GUI name'}}
Write-Host "[PASS] GUI XML and $($controls.Count) named controls"
$env:YDR_DATA_HOME=Join-Path $env:TEMP ('YDR-PS-Security-Test-'+[guid]::NewGuid().ToString('N'))
try {
    Import-Module (Join-Path $root 'YDR.Core.psm1') -Force -ErrorAction Stop
    Initialize-YdrData
    $secret='test_oauth_token_abcdefghijklmnopqrstuvwxyz'
    Save-YdrToken $secret
    if ((Get-YdrToken) -ne $secret){throw 'DPAPI round trip mismatch'}
    if ((Hide-YdrSecret -Text "my token: $secret" -OAuthToken $secret).Contains($secret)){throw 'Log redaction failed'}
    Remove-YdrToken
    if (Get-YdrToken){throw 'Token deletion failed'}
    Write-Host '[PASS] DPAPI token save/read/delete + redaction'
    $job=New-YdrJob -Kind 'Copy' -Source 'ydr:Фото' -Destination 'C:\YDRTest' -Serial 'AA11' -Verify $true
    Add-YdrJob $job
    $read=@(Get-YdrJobs)
    if ($read.Count -ne 1 -or $read[0].Id -ne $job.Id){throw 'Queue round trip failed'}
    Update-YdrJob -Id $job.Id -State 'Приостановлено' -Details 'Test'
    if ((Get-YdrJob $job.Id).State -ne 'Приостановлено'){throw 'Queue update failed'}
    Reset-YdrJob -Id $job.Id
    if ((Get-YdrJob $job.Id).State -ne 'Ожидает'){throw 'Queue resume failed'}
    $quote=Quote-YdrArgument 'C:\Users\Sample User\file "demo".txt'
    if (-not $quote.StartsWith('"') -or -not $quote.EndsWith('"')){throw 'Quoting failed'}
    Write-Host '[PASS] Atomic queue, reset and Windows arguments'
    $module=Get-Content (Join-Path $root 'YDR.Core.psm1') -Raw -Encoding UTF8
    if($module.Contains('GetEnvironmentVariable("PATH")') -or $module -match 'Start-Process\s+https?://'){throw 'Unexpected executable fallback'}
    if($module -notmatch "\('about','lsf','copy','check'\)"){throw 'Unsafe or missing rclone verb allowlist'}
    Write-Host '[PASS] Security policy static assertions'
}
finally {
    Remove-Module YDR.Core -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $env:YDR_DATA_HOME -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:YDR_DATA_HOME -ErrorAction SilentlyContinue
}
# Verify that the actual WPF visual tree loads under Windows PowerShell 5.1 (not just XML parsing).
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$xr=[Xml.XmlReader]::Create((Join-Path $root 'MainWindow.xaml'))
try {
    $win=[Windows.Markup.XamlReader]::Load($xr)
    foreach($name in @('TokenBox','AddJobButton','JobsList','PhotoRescueButton','OutputBox')){
        if(-not $win.FindName($name)){throw "WPF missing element $name"}
    }
    $win.Close()
} finally { $xr.Dispose() }
Write-Host '[PASS] WPF XamlReader and named controls'
# The background worker must exit cleanly with an empty queue and no OAuth token.
& (Join-Path $root 'YDR.Worker.ps1') -SinglePass
Write-Host '[PASS] Background PS worker starts and exits'

Write-Host '[PASS] PowerShell GUI smoke suite'
