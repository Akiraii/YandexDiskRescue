#requires -Version 5.1
# PowerShell-only core for Yandex Disk Rescue. No dynamically compiled C#.
Set-StrictMode -Version 2.0
$script:YdrProgramRoot = $PSScriptRoot
$script:YdrDataRoot = if ($env:YDR_DATA_HOME) { [IO.Path]::GetFullPath($env:YDR_DATA_HOME) } else { Join-Path $env:LOCALAPPDATA 'YandexDiskRescue\PowerShell' }
$script:YdrMutexName = 'Local\YDR_PS_Queue_' + ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -replace '[^a-zA-Z0-9_-]', '_')
$script:HelperSha256 = 'F3A5EABC666F2A75B1A637A319F647A87B2201DAD3CF3650EF532A054BBABBD4'

function Get-YdrRoot { return $script:YdrDataRoot }
function Get-YdrProgramRoot { return $script:YdrProgramRoot }
function Get-YdrDataPath([string]$Relative) { return Join-Path $script:YdrDataRoot $Relative }
function Protect-YdrDirectory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { [void](New-Item -ItemType Directory -Path $Path -Force) }
    # App state, including cookies/manifests, must not inherit broad Users/Everyone ACLs.
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $flags = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $none = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $acl.AddAccessRule((New-Object -TypeName Security.AccessControl.FileSystemAccessRule -ArgumentList @($identity, [Security.AccessControl.FileSystemRights]::FullControl, $flags, $none, $allow)))
    $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $acl.AddAccessRule((New-Object -TypeName Security.AccessControl.FileSystemAccessRule -ArgumentList @($system, [Security.AccessControl.FileSystemRights]::FullControl, $flags, $none, $allow)))
    [IO.Directory]::SetAccessControl($Path, $acl)
}
function Initialize-YdrData {
    Protect-YdrDirectory $script:YdrDataRoot
    foreach ($folder in @('config','data','log','reports','unlimited-state','chrome-profile')) {
        Protect-YdrDirectory (Get-YdrDataPath $folder)
    }
}
function Hide-YdrSecret([string]$Text, [string]$OAuthToken = '') {
    if ($null -eq $Text) { return '' }
    $safe = $Text
    if ($OAuthToken) { $safe = $safe.Replace($OAuthToken,'[REDACTED]') }
    $safe = [regex]::Replace($safe, '(?i)(\b(?:access_token|refresh_token|oauth_token|client_secret|Authorization|sk)\b\s*[:=]\s*[\"'']?)[^\s,;\"''&}]+', '$1[REDACTED]')
    $safe = [regex]::Replace($safe, '(?i)([?&](?:token|access_token|oauth_token|sig|signature|auth|sk|key)=)[^&\s]+', '$1[REDACTED]')
    return $safe
}
function Write-YdrLog([string]$Message, [string]$OAuthToken = '') {
    Initialize-YdrData
    $file = Get-YdrDataPath 'log\worker.log'
    $safe = Hide-YdrSecret -Text $Message -OAuthToken $OAuthToken
    if ($safe.Length -gt 30000) { $safe=$safe.Substring(0,30000)+' [TRUNCATED]' }
    $line = (Get-Date -Format o) + ' ' + $safe + [Environment]::NewLine
    [IO.File]::AppendAllText($file, $line, (New-Object Text.UTF8Encoding($false)))
    try {
        if ((Get-Item -LiteralPath $file).Length -gt 10MB) {
            $archive=$file+'.1'
            Move-Item -LiteralPath $file -Destination $archive -Force
        }
    } catch { }
}
function Save-YdrToken([string]$OAuthToken) {
    if ($OAuthToken -notmatch '^[A-Za-z0-9_.-]{20,}$') { throw 'Недопустимый формат OAuth-токена' }
    Initialize-YdrData
    $bytes = [Text.Encoding]::UTF8.GetBytes($OAuthToken)
    $encrypted = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    [IO.File]::WriteAllBytes((Get-YdrDataPath 'config\token.dpapi'), $encrypted)
    [Array]::Clear($bytes,0,$bytes.Length)
}
function Get-YdrToken {
    $file = Get-YdrDataPath 'config\token.dpapi'
    if (-not [IO.File]::Exists($file)) { return $null }
    $decrypted=[Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($file), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    try { return [Text.Encoding]::UTF8.GetString($decrypted) }
    finally { [Array]::Clear($decrypted, 0, $decrypted.Length) }
}
function Remove-YdrToken {
    $file=Get-YdrDataPath 'config\token.dpapi'
    if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) }
}
function Invoke-YdrQueueLock([scriptblock]$Action) {
    Initialize-YdrData
    $mutex = New-Object Threading.Mutex($false, $script:YdrMutexName)
    $held=$false
    try {
        try { $held=$mutex.WaitOne([TimeSpan]::FromSeconds(15)) }
        catch [Threading.AbandonedMutexException] { $held=$true }
        if (-not $held) { throw 'Очередь заданий временно занята' }
        & $Action
    }
    finally { if ($held) { [void]$mutex.ReleaseMutex() }; $mutex.Dispose() }
}
function Read-YdrJobsUnsafe {
    $path=Get-YdrDataPath 'data\jobs.json'
    if (-not [IO.File]::Exists($path)) { return ,@() }
    $json=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($json)) { throw 'Повреждена очередь jobs.json' }
    $items=ConvertFrom-Json -InputObject $json
    if ($null -eq $items) { return ,@() }
    if ($items -isnot [array]) { throw 'Неверный формат очереди jobs.json' }
    return ,@($items)
}
function Write-YdrJobsUnsafe([object[]]$Jobs) {
    $path=Get-YdrDataPath 'data\jobs.json'
    $json=ConvertTo-Json -InputObject @($Jobs) -Depth 16 -Compress
    $tmp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
    try {
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($tmp,$path,$null) }
        else { [IO.File]::Move($tmp,$path) }
    }
    finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
}
function Get-YdrJobs {
    $result=Invoke-YdrQueueLock { return ,(Read-YdrJobsUnsafe) }
    return ,@($result)
}
function Edit-YdrJobs([scriptblock]$Edit, [object[]]$Arguments = @()) {
    Invoke-YdrQueueLock {
        $list=New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in (Read-YdrJobsUnsafe)) { $list.Add($item) }
        & $Edit $list @Arguments
        Write-YdrJobsUnsafe -Jobs @($list.ToArray())
    }
}
function New-YdrJob([string]$Kind, [string]$Source, [string]$Destination,
                    [string]$Serial, [int]$Transfers = 8, [int]$LimitKiB = 0, [bool]$Verify = $true,
                    [string]$Manifest = '', [string]$ScheduledUtc = '') {
    return [pscustomobject]@{
        Id=[guid]::NewGuid().ToString('N'); Kind=$Kind; Source=$Source; Destination=$Destination
        VolumeSerial=$Serial; Transfers=[Math]::Min(32,[Math]::Max(1,$Transfers)); LimitKiB=$LimitKiB
        Verify=$Verify; Manifest=$Manifest; State='Ожидает'; Details=''; CreatedUtc=[datetime]::UtcNow.ToString('o')
        ScheduledUtc=$ScheduledUtc; RetryCount=0; NextAttemptUtc=''; Report=''
    }
}
function Add-YdrJob([object]$Job) {
    Edit-YdrJobs -Edit { param($jobs,$item) [void]$jobs.Add($item) } -Arguments @($Job)
}
function Update-YdrJob([string]$Id, [string]$State, [string]$Details = '', [string]$Report = '') {
    Edit-YdrJobs -Edit {
        param($jobs,$key,$newState,$newDetails,$newReport)
        foreach($j in $jobs) {
            if ($j.Id -eq $key) {
                $j.State=$newState; $j.Details=$newDetails
                if ($newReport) { $j.Report=$newReport }
                break
            }
        }
    } -Arguments @($Id,$State,$Details,$Report)
}
function Reset-YdrJob([string]$Id) {
    Edit-YdrJobs -Edit {
        param($jobs,$key)
        foreach($j in $jobs) {
            if($j.Id -eq $key) {
                $j.State='Ожидает';$j.Details='';$j.RetryCount=0;$j.NextAttemptUtc='';$j.ScheduledUtc=''
                break
            }
        }
    } -Arguments @($Id)
}
function Get-YdrJob([string]$Id) {
    foreach($j in (Get-YdrJobs)) { if ($j.Id -eq $Id) { return $j } }
    return $null
}
function Get-YdrVolumeSerial([string]$Folder) {
    if ([string]::IsNullOrWhiteSpace($Folder)) { throw 'Укажите локальную папку назначения' }
    $full=[IO.Path]::GetFullPath($Folder)
    if (-not [IO.Path]::IsPathRooted($full) -or $full.StartsWith('\\')) { throw 'Используйте локальный или USB-диск, а не сетевую папку' }
    $root=[IO.Path]::GetPathRoot($full)
    if (-not $root -or -not [IO.Directory]::Exists($root)) { throw 'Диск назначения не подключён' }
    if ($root -notmatch '^[A-Za-z]:\\$') { throw 'Нужен диск с буквой (например D:\)' }
    $device=$root.Substring(0,2)
    $disk=Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='"+$device+"'") -ErrorAction Stop
    if (-not $disk -or -not $disk.VolumeSerialNumber) { throw 'Не удалось получить серийный номер тома' }
    return [string]$disk.VolumeSerialNumber
}
function Assert-YdrDestination([string]$Folder,[string]$ExpectedSerial) {
    $full=[IO.Path]::GetFullPath($Folder)
    if ([string]::IsNullOrWhiteSpace($ExpectedSerial)) { throw 'Нет привязки задания к диску назначения' }
    if ((Get-YdrVolumeSerial -Folder $full) -ne $ExpectedSerial) { throw 'Подключён другой диск: запись заблокирована' }
    return $full
}
function Assert-YdrSource([string]$Path) {
    $value=$Path.Trim().Replace('\','/').TrimStart('/')
    if ($value.StartsWith('ydr:',[StringComparison]::OrdinalIgnoreCase)) { throw 'Путь указывается без префикса ydr:' }
    if ($value -match '[\r\n]' -or @($value.Split('/')) -contains '..' -or @($value.Split('/')) -contains '.') { throw 'Недопустимый облачный путь' }
    return 'ydr:'+$value
}
function Quote-YdrArgument([string]$Value) {
    # Correct CreateProcess quoting, including trailing backslashes and embedded quotes.
    $b = New-Object Text.StringBuilder
    [void]$b.Append('"'); $slashes=0
    foreach($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') { $slashes++; continue }
        if ($ch -eq '"') { [void]$b.Append(('\' * ($slashes*2+1))); [void]$b.Append('"'); $slashes=0; continue }
        if ($slashes) { [void]$b.Append(('\' * $slashes)); $slashes=0 }
        [void]$b.Append($ch)
    }
    if ($slashes) { [void]$b.Append(('\' * ($slashes*2))) }
    [void]$b.Append('"'); return $b.ToString()
}
function Invoke-YdrChild([string]$Executable,[string[]]$Arguments,[hashtable]$Environment = @{},
                         [string]$CancelJobId = '',[string]$OAuthToken = '') {
    if (-not [IO.File]::Exists($Executable)) { throw "Отсутствует обязательный файл: $Executable" }
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$Executable
    $psi.Arguments=(@($Arguments) | ForEach-Object { Quote-YdrArgument ([string]$_) }) -join ' '
    $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
    $psi.StandardOutputEncoding=[Text.Encoding]::UTF8; $psi.StandardErrorEncoding=[Text.Encoding]::UTF8
    $psi.WorkingDirectory=[IO.Path]::GetDirectoryName($Executable)
    foreach($k in $Environment.Keys) { $psi.EnvironmentVariables[[string]$k]=[string]$Environment[$k] }
    $p=New-Object Diagnostics.Process
    $p.StartInfo=$psi
    try {
        if (-not $p.Start()) { throw 'Процесс не запустился' }
        $stdout=$p.StandardOutput.ReadToEndAsync()
        $stderr=$p.StandardError.ReadToEndAsync()
        $cancelled=$false
        while(-not $p.WaitForExit(400)) {
            if ($CancelJobId) {
                $job=Get-YdrJob $CancelJobId
                if ($null -eq $job -or $job.State -in @('Приостановлено','Отменено')) {
                    $cancelled=$true; try { $p.Kill() } catch { }; break
                }
            }
        }
        $p.WaitForExit()
        $combined=$stdout.GetAwaiter().GetResult() + [Environment]::NewLine + $stderr.GetAwaiter().GetResult()
        $combined=Hide-YdrSecret -Text $combined -OAuthToken $OAuthToken
        if ($cancelled) { throw [OperationCanceledException]::new('Задание приостановлено или отменено') }
        return [pscustomobject]@{ ExitCode=$p.ExitCode; Output=$combined }
    }
    finally { $p.Dispose() }
}
function Invoke-YdrRclone([string]$Verb,[string[]]$Arguments,[string]$OAuthToken,[string]$CancelJobId = '') {
    if ($Verb -notin @('about','lsf','copy','check')) { throw 'Недопустимая операция rclone' }
    $path=Join-Path $script:YdrProgramRoot 'tools\rclone.exe'
    # Never fall back to PATH: OAuth is sent to the child process.
    $config=@{
        RCLONE_CONFIG_YDR_TYPE='yandex'
        RCLONE_CONFIG_YDR_TOKEN=(ConvertTo-Json -InputObject @{access_token=$OAuthToken;token_type='OAuth';refresh_token='unused';expiry='2099-01-01T00:00:00Z'} -Compress)
    }
    return Invoke-YdrChild -Executable $path -Arguments (@('--config','NUL',$Verb)+$Arguments) -Environment $config -CancelJobId $CancelJobId -OAuthToken $OAuthToken
}
function Get-YdrQuota([string]$OAuthToken) {
    $headers=@{Authorization=('OAuth '+$OAuthToken)}
    $uri='https://cloud-api.yandex.net/v1/disk/?fields=photounlim_size,total_space,used_space,user.uid'
    $r=Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -TimeoutSec 25 -ErrorAction Stop
    $uid=[string]$r.user.uid
    if ($uid -notmatch '^\d+$') { throw 'API не вернул числовой UID аккаунта' }
    $size=[long]$r.photounlim_size; $free=[Math]::Max([long]0, ([long]$r.total_space - [long]$r.used_space))
    return [pscustomobject]@{Uid=$uid;Unlimited=$size;Free=$free;Enough=($size -gt 0 -and $free -ge ($size + [Math]::Ceiling($size*0.05)))}
}
function Ensure-YdrCloudFolder([string]$OAuthToken) {
    $url='https://cloud-api.yandex.net/v1/disk/resources?path='+[Uri]::EscapeDataString('disk:/Безлимит')+'&fields=type'
    $headers=@{Authorization=('OAuth '+$OAuthToken)}
    try { $existing=Invoke-RestMethod -Uri $url -Method Get -Headers $headers -TimeoutSec 25 -ErrorAction Stop; if ($existing.type -ne 'dir') { throw 'Путь «Безлимит» занят файлом' }; return }
    catch {
        $status=$null
        if ($_.Exception.Response) { $status=[int]$_.Exception.Response.StatusCode }
        if ($status -ne 404) { throw }
    }
    try { $null=Invoke-RestMethod -Uri $url -Method Put -Headers $headers -TimeoutSec 25 -ErrorAction Stop }
    catch {
        if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 409) { throw }
    }
    $check=Invoke-RestMethod -Uri $url -Method Get -Headers $headers -TimeoutSec 25 -ErrorAction Stop
    if ($check.type -ne 'dir') { throw 'Не удалось подтвердить папку Безлимит' }
}
function Read-YdrPhotoState {
    $base=Get-YdrDataPath 'unlimited-state'
    $listfile=Join-Path $base 'unlim_list.json'
    if (-not [IO.File]::Exists($listfile)) { throw 'Список фотографий ещё не создан' }
    $manifest=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($listfile,[Text.Encoding]::UTF8))
    $items=@($manifest.items)
    if ($items.Count -lt 1 -or $items.Count -ne [int]$manifest.expected -or @($items|Select-Object -Unique).Count -ne $items.Count) { throw 'Неполный либо дублированный список фотографий' }
    $moved = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $moves=Join-Path $base 'moved.jsonl'
    if ([IO.File]::Exists($moves)) {
        foreach($line in [IO.File]::ReadAllLines($moves,[Text.Encoding]::UTF8)) {
            if (-not $line.Trim()) { continue }
            try { $entry=ConvertFrom-Json -InputObject $line; if ($entry.ok -eq $true -and $entry.src) { [void]$moved.Add([string]$entry.src) } } catch { }
        }
    }
    $count=0; foreach($s in $items) { if ($moved.Contains([string]$s)) { $count++ } }
    return [pscustomobject]@{Expected=[int]$manifest.expected;Listed=$items.Count;Moved=$count;Items=$items;MovedSet=$moved}
}
function Assert-YdrHelper {
    $helper=Join-Path $script:YdrProgramRoot 'tools\yd.js'
    $node=Join-Path $script:YdrProgramRoot 'tools\node.exe'
    if (-not [IO.File]::Exists($node)) { throw 'Встроенный node.exe отсутствует. Используйте полный Portable-комплект' }
    if (-not [IO.File]::Exists($helper)) { throw 'Встроенный yd.js отсутствует' }
    $sha=(Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash
    if ($sha -ne $script:HelperSha256) { throw 'Контрольная сумма yd.js не совпадает: выполнение заблокировано' }
    return [pscustomobject]@{Node=$node;Helper=$helper}
}
function Get-YdrChromeEndpoint {
    $metaPath=Get-YdrDataPath 'config\chrome-launch.json'
    $profile=Get-YdrDataPath 'chrome-profile'
    if (-not [IO.File]::Exists($metaPath)) { throw 'Сначала запустите отдельный Chrome из программы' }
    $meta=ConvertFrom-Json ([IO.File]::ReadAllText($metaPath))
    $p=Get-Process -Id ([int]$meta.Pid) -ErrorAction SilentlyContinue
    if (-not $p -or $p.HasExited) { throw 'Отдельный Chrome больше не запущен' }
    $started=[datetime]::Parse([string]$meta.StartUtc)
    if ([Math]::Abs(($p.StartTime.ToUniversalTime() - $started).TotalSeconds) -gt 5) { throw 'Сессия Chrome не совпадает с сохранённой' }
    $portfile=Join-Path $profile 'DevToolsActivePort'
    if (-not [IO.File]::Exists($portfile)) { throw 'Chrome ещё не открыл порт отладки' }
    $portline=([IO.File]::ReadAllLines($portfile))[0]
    $port=0
    if (-not [int]::TryParse($portline,[ref]$port) -or $port -lt 1024 -or $port -gt 65535) { throw 'Некорректный порт Chrome' }
    return ('http://127.0.0.1:'+ $port)
}
function Start-YdrChrome {
    Initialize-YdrData
    $existing=$null
    try { $existing=Get-YdrChromeEndpoint } catch { }
    if ($existing) { throw 'Отдельный Chrome уже открыт. Используйте существующее окно' }
    $chrome=@(
        (Join-Path ${env:ProgramFiles} 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe')
    ) | Where-Object { $_ -and [IO.File]::Exists($_) } | Select-Object -First 1
    if (-not $chrome) { throw 'Google Chrome не найден в стандартных папках' }
    $profile=Get-YdrDataPath 'chrome-profile'
    $portfile=Join-Path $profile 'DevToolsActivePort'
    if ([IO.File]::Exists($portfile)) { [IO.File]::Delete($portfile) }
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$chrome; $psi.UseShellExecute=$false
    $psi.Arguments=(@('--remote-debugging-address=127.0.0.1','--remote-debugging-port=0','--disable-extensions','--disable-sync','--no-first-run',('--user-data-dir='+$profile),'https://disk.yandex.ru/client/photo') | ForEach-Object { Quote-YdrArgument $_ }) -join ' '
    $proc=[Diagnostics.Process]::Start($psi)
    if (-not $proc) { throw 'Не удалось запустить Chrome' }
    $meta=@{Pid=$proc.Id;StartUtc=$proc.StartTime.ToUniversalTime().ToString('o')} | ConvertTo-Json -Compress
    [IO.File]::WriteAllText((Get-YdrDataPath 'config\chrome-launch.json'),$meta)
    $proc.Dispose()
}
function Invoke-YdrPhotoScript([string]$Action,[string]$OAuthToken,[string]$CancelJobId='') {
    if ($Action -notin @('list','move')) { throw 'Недопустимая операция yd.js' }
    $b=Assert-YdrHelper
    $quota=Get-YdrQuota -OAuthToken $OAuthToken
    if ($Action -eq 'move') {
        $photo=Read-YdrPhotoState
        if ($photo.Listed -ne $photo.Expected -or -not $quota.Enough) { throw 'Перенос заблокирован: список неполный или недостаточно обычной квоты с запасом 5%' }
        Ensure-YdrCloudFolder -OAuthToken $OAuthToken
    }
    $endpoint=Get-YdrChromeEndpoint
    $args=@($b.Helper,$Action,(Get-YdrDataPath 'unlimited-state'))
    if ($Action -eq 'move') { $args+=@('2147483647','40') }
    return Invoke-YdrChild -Executable $b.Node -Arguments $args -Environment @{YD_CDP=$endpoint;YD_EXPECTED_UID=$quota.Uid} -CancelJobId $CancelJobId
}
function New-YdrPhotoSnapshot {
    $state=Read-YdrPhotoState
    if ($state.Moved -lt 1 -or $state.Listed -ne $state.Expected) { throw 'Нет подтверждённых переносов или список неполный' }
    $file=Get-YdrDataPath ('data\photo-'+[guid]::NewGuid().ToString('N')+'.json')
    $snapshot=@{ Expected=$state.Expected;Listed=@($state.Items);Moved=@($state.Items | Where-Object { $state.MovedSet.Contains([string]$_) }) }
    [IO.File]::WriteAllText($file,(ConvertTo-Json -InputObject $snapshot -Depth 5 -Compress),(New-Object Text.UTF8Encoding($false)))
    return $file
}
function Export-YdrCheckReport([object]$Job, [int]$CheckCode) {
    $folder=Get-YdrDataPath 'reports'; $report=Join-Path $folder ($Job.Id+'.combined.txt')
    $csv=Join-Path $folder ($Job.Id+'.csv'); $html=Join-Path $folder ($Job.Id+'.html')
    $rows=New-Object 'System.Collections.Generic.List[object]'
    if ([IO.File]::Exists($report)) {
        foreach($line in [IO.File]::ReadLines($report)) {
            if ($line.Length -lt 3 -or $line[1] -ne ' ') { continue }
            $rows.Add([pscustomobject]@{Status=$line[0].ToString();Path=$line.Substring(2)})
        }
    }
    $enc=New-Object Text.UTF8Encoding($true)
    $w=New-Object IO.StreamWriter($csv,$false,$enc)
    try {
        $w.WriteLine('Статус;Путь')
        foreach($row in $rows) {
            $status=[string]$row.Status; $path=[string]$row.Path
            if ($path -match '^[=+\-@\t\r\n]') { $path="'"+$path }
            $w.WriteLine(('"'+($status -replace '"','""')+'";"'+($path -replace '"','""')+'"'))
        }
    } finally { $w.Dispose() }
    $builder=New-Object Text.StringBuilder
    [void]$builder.Append('<!doctype html><html lang="ru"><meta charset="utf-8"><title>Проверка Yandex Disk Rescue</title><style>body{font:14px Segoe UI;background:#111827;color:#eee;margin:30px}td,th{padding:7px;border-bottom:1px solid #444;text-align:left}</style><h1>Проверка резервной копии</h1><table><tr><th>Статус</th><th>Путь</th></tr>')
    foreach($row in $rows) { [void]$builder.Append('<tr><td>').Append([Net.WebUtility]::HtmlEncode([string]$row.Status)).Append('</td><td>').Append([Net.WebUtility]::HtmlEncode([string]$row.Path)).Append('</td></tr>') }
    [void]$builder.Append('</table><p>rclone check: ').Append($CheckCode).Append('</p></html>')
    [IO.File]::WriteAllText($html,$builder.ToString(),(New-Object Text.UTF8Encoding($false)))
    return [pscustomobject]@{Html=$html;Csv=$csv;Rows=@($rows)}
}
function Get-YdrAutostart {
    $key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    try { return [bool](Get-ItemPropertyValue -Path $key -Name 'YDRPowerShellWorker' -ErrorAction Stop) } catch { return $false }
}
function Set-YdrAutostart([bool]$Enabled) {
    $key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if (-not $Enabled) { Remove-ItemProperty -Path $key -Name 'YDRPowerShellWorker' -ErrorAction SilentlyContinue;return }
    $worker=Join-Path $script:YdrProgramRoot 'YDR.Worker.ps1'
    $powershell=Join-Path $PSHOME 'powershell.exe'
    if (-not [IO.File]::Exists($powershell)) { $powershell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $cmd='"'+$powershell+'" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$worker+'"'
    New-Item -Path $key -Force | Out-Null
    Set-ItemProperty -Path $key -Name 'YDRPowerShellWorker' -Type String -Value $cmd
}
function Start-YdrWorker {
    $powershell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $worker=Join-Path $script:YdrProgramRoot 'YDR.Worker.ps1'
    if (-not [IO.File]::Exists($powershell) -or -not [IO.File]::Exists($worker)) { throw 'Нет PowerShell 5.1 или фонового worker.ps1' }
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$powershell; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $psi.Arguments='-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File '+(Quote-YdrArgument $worker)
    $p=[Diagnostics.Process]::Start($psi)
    if (-not $p) { throw 'Не удалось запустить фонового исполнителя' }
    $p.Dispose()
}
Export-ModuleMember -Function Get-YdrRoot,Get-YdrProgramRoot,Get-YdrDataPath,Initialize-YdrData,Hide-YdrSecret,Write-YdrLog,Save-YdrToken,Get-YdrToken,Remove-YdrToken,Get-YdrJobs,Edit-YdrJobs,Reset-YdrJob,New-YdrJob,Add-YdrJob,Update-YdrJob,Get-YdrJob,Get-YdrVolumeSerial,Assert-YdrDestination,Assert-YdrSource,Quote-YdrArgument,Invoke-YdrChild,Invoke-YdrRclone,Get-YdrQuota,Ensure-YdrCloudFolder,Read-YdrPhotoState,Assert-YdrHelper,Get-YdrChromeEndpoint,Start-YdrChrome,Invoke-YdrPhotoScript,New-YdrPhotoSnapshot,Export-YdrCheckReport,Get-YdrAutostart,Set-YdrAutostart,Start-YdrWorker
