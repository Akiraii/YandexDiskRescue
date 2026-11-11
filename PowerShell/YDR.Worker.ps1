#requires -Version 5.1
# Background executor. Never pass OAuth tokens through command-line arguments.
param([switch]$SinglePass)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'YDR.Core.psm1') -Force
Initialize-YdrData
$mutexName='Local\YDR_PS_Worker_'+([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -replace '[^A-Za-z0-9_-]','_')
$created=$false
$singleton=[Threading.Mutex]::new($true,$mutexName,[ref]$created)
if (-not $created) { $singleton.Dispose(); return }

function Set-JobRetry([object]$Job,[string]$Reason) {
    $retry=[int]$Job.RetryCount + 1
    if ($retry -ge 5) { Update-YdrJob -Id $Job.Id -State 'Ошибка' -Details ('После 5 попыток: '+$Reason);return }
    $next=[datetime]::UtcNow.AddMinutes([Math]::Min(60,[Math]::Pow(2,$retry)))
    Edit-YdrJobs -Edit {
        param($jobs,$key,$count,$nextUtc,$details)
        foreach($j in $jobs) { if ($j.Id -eq $key) {
            $j.RetryCount=$count; $j.NextAttemptUtc=$nextUtc;$j.Details=$details;$j.State='Ожидает'; break
        } }
    } -Arguments @($Job.Id,$retry,$next.ToString('o'),$Reason)
}
function Assert-JobActive([string]$Id) {
    $j=Get-YdrJob $Id
    if (-not $j -or $j.State -in @('Приостановлено','Отменено')) { throw [OperationCanceledException]::new('Задание остановлено пользователем') }
}
function Invoke-YdrCopyAndVerify([object]$Job,[string]$Token,[bool]$Unlimited=$false) {
    $dest=Assert-YdrDestination -Folder $Job.Destination -ExpectedSerial $Job.VolumeSerial
    [IO.Directory]::CreateDirectory($dest) | Out-Null
    $source=if($Unlimited){'ydr:Безлимит'}else{[string]$Job.Source}
    if (-not $source.StartsWith('ydr:',[StringComparison]::Ordinal)) { throw 'Допустим только источник Яндекс Диск (ydr:)' }
    $manifest=''
    if ($Unlimited) { $manifest=New-YdrPhotoSnapshot }
    if ($Job.Kind -ne 'Check') {
        Update-YdrJob -Id $Job.Id -State 'Копирование'
        $args=@($source,$dest,'--transfers',[string]$Job.Transfers,'--checkers','8',
                '--bwlimit',($(if([int]$Job.LimitKiB -gt 0){"$($Job.LimitKiB)k"}else{'off'})),
                '--immutable','--retries','2','--low-level-retries','2','--timeout','60s','--stats','10s')
        $cp=Invoke-YdrRclone -Verb 'copy' -Arguments $args -OAuthToken $Token -CancelJobId $Job.Id
        Write-YdrLog "Job $($Job.Id): rclone copy exit $($cp.ExitCode) $($cp.Output)" -OAuthToken $Token
    } else { $cp=[pscustomobject]@{ExitCode=0;Output='Only check'} }
    Assert-JobActive $Job.Id
    if (-not $Job.Verify -and -not $Unlimited -and $Job.Kind -ne 'Check') {
        if ($cp.ExitCode -eq 0) { Update-YdrJob -Id $Job.Id -State 'Завершено' -Details 'Скачано без проверки (не рекомендуется)' }
        else { Set-JobRetry $Job 'Копирование завершилось с ошибкой' }
        return
    }
    Update-YdrJob -Id $Job.Id -State 'Проверка'
    $combined=Get-YdrDataPath ('reports\'+$Job.Id+'.combined.txt')
    if([IO.File]::Exists($combined)){[IO.File]::Delete($combined)}
    $args=@($source,$dest,'--one-way','--combined',$combined,'--download')
    $check=Invoke-YdrRclone -Verb 'check' -Arguments $args -OAuthToken $Token -CancelJobId $Job.Id
    Write-YdrLog "Job $($Job.Id): rclone check exit $($check.ExitCode) $($check.Output)" -OAuthToken $Token
    $report=Export-YdrCheckReport -Job $Job -CheckCode $check.ExitCode
    $allVerified=$true
    $detail="Копирование $($cp.ExitCode), проверка $($check.ExitCode). HTML: $($report.Html)"
    if ($Unlimited) {
        $snapshot=ConvertFrom-Json ([IO.File]::ReadAllText($manifest,[Text.Encoding]::UTF8))
        $statuses=@{}
        foreach($row in $report.Rows) { $statuses[[string]$row.Path.Replace('\','/')]=[string]$row.Status }
        $verified=0
        foreach($src in $snapshot.Listed) {
            if($src -notmatch '^/photounlim/[^/]+') { $allVerified=$false; continue }
            if(@($snapshot.Moved) -notcontains $src) { $allVerified=$false; continue }
            $rel=$src.Substring('/photounlim/'.Length)
            if($statuses.ContainsKey($rel) -and $statuses[$rel] -eq '='){$verified++}else{$allVerified=$false}
        }
        $detail += "; фото подтверждено $verified/$($snapshot.Expected)"
    }
    if ($cp.ExitCode -eq 0 -and $check.ExitCode -eq 0 -and $allVerified) {
        Update-YdrJob -Id $Job.Id -State 'Завершено' -Details $detail -Report $report.Html
        if ($Job.PSObject.Properties.Name -contains 'RecurringDaily' -and $Job.RecurringDaily -eq $true -and -not $Unlimited) {
            # Schedule next occurrence, never repeat photo moves.
            $next=(Get-Date).Date.AddDays(1).AddHours(9)
            $clone=New-YdrJob -Kind 'Copy' -Source $Job.Source -Destination $Job.Destination -Serial $Job.VolumeSerial -Transfers $Job.Transfers -LimitKiB $Job.LimitKiB -Verify ([bool]$Job.Verify) -ScheduledUtc $next.ToUniversalTime().ToString('o')
            $clone | Add-Member -NotePropertyName RecurringDaily -NotePropertyValue $true
            Add-YdrJob $clone
        }
    } elseif($Unlimited) {
        Update-YdrJob -Id $Job.Id -State 'Неполный архив' -Details $detail -Report $report.Html
    } else {
        Set-JobRetry $Job $detail
    }
}
function Invoke-YdrJob([object]$Job) {
    $token=Get-YdrToken
    if ([string]::IsNullOrWhiteSpace($token)) { Update-YdrJob -Id $Job.Id -State 'Нужна авторизация' -Details 'Разрешите защищённое хранение токена (DPAPI)'; return }
    switch([string]$Job.Kind) {
        'Copy'           { Invoke-YdrCopyAndVerify -Job $Job -Token $token }
        'Check'          { Invoke-YdrCopyAndVerify -Job $Job -Token $token }
        'PhotoList' {
            Update-YdrJob -Id $Job.Id -State 'Сбор списка'
            $r=Invoke-YdrPhotoScript -Action 'list' -OAuthToken $token -CancelJobId $Job.Id
            Write-YdrLog "Photo list $($Job.Id): $($r.Output)" -OAuthToken $token
            if($r.ExitCode -ne 0){throw "Список фотографий не получен (код $($r.ExitCode))"}
            $state=Read-YdrPhotoState
            Update-YdrJob -Id $Job.Id -State 'Завершено' -Details "Собрано фото $($state.Listed)/$($state.Expected)"
        }
        'PhotoMove' {
            Update-YdrJob -Id $Job.Id -State 'Перенос в облаке'
            $state=Read-YdrPhotoState
            if($state.Moved -lt $state.Listed){
                $r=Invoke-YdrPhotoScript -Action 'move' -OAuthToken $token -CancelJobId $Job.Id
                Write-YdrLog "Photo move $($Job.Id): $($r.Output)" -OAuthToken $token
                if($r.ExitCode -ne 0){throw "Перенос завершился с ошибкой (код $($r.ExitCode))"}
            }
            $after=Read-YdrPhotoState
            if ($after.Moved -ne $after.Listed) {throw "Перенос неполный $($after.Moved)/$($after.Listed)"}
            Update-YdrJob -Id $Job.Id -State 'Завершено' -Details "Перенесено $($after.Moved)/$($after.Listed)"
        }
        'PhotoDownload' { Invoke-YdrCopyAndVerify -Job $Job -Token $token -Unlimited $true }
        'PhotoRescue' {
            Update-YdrJob -Id $Job.Id -State 'Сбор списка'
            $state=$null
            try {$state=Read-YdrPhotoState}catch { }
            if(-not $state){
                $list=Invoke-YdrPhotoScript -Action 'list' -OAuthToken $token -CancelJobId $Job.Id
                Write-YdrLog "Rescue list $($Job.Id): $($list.Output)" -OAuthToken $token
                if($list.ExitCode -ne 0){throw 'Не удалось собрать полный список фотографий'}
            }
            $state=Read-YdrPhotoState
            Assert-JobActive $Job.Id
            if($state.Moved -lt $state.Listed){
                Update-YdrJob -Id $Job.Id -State 'Перенос в облаке'
                $move=Invoke-YdrPhotoScript -Action 'move' -OAuthToken $token -CancelJobId $Job.Id
                Write-YdrLog "Rescue move $($Job.Id): $($move.Output)" -OAuthToken $token
                $state=Read-YdrPhotoState
                if ($state.Moved -lt 1 -or $move.ExitCode -ne 0) { throw "Перенос прерван: $($state.Moved)/$($state.Listed)" }
            }
            Assert-JobActive $Job.Id
            Invoke-YdrCopyAndVerify -Job $Job -Token $token -Unlimited $true
        }
        default { throw 'Неизвестный тип задания: '+$Job.Kind }
    }
}

try {
    # Do not auto-mark interrupted moves as complete. Retry from append-only evidence.
    Edit-YdrJobs {
        param($jobs)
        foreach($j in $jobs) { if($j.State -in @('Копирование','Проверка','Сбор списка','Перенос в облаке')) {
            $j.State='Ожидает';$j.Details='Возобновление после прерывания — требуется повторная сверка'
        } }
    }
    while($true) {
        $job=$null
        foreach($j in (Get-YdrJobs)) {
            if($j.State -ne 'Ожидает'){continue}
            if($j.ScheduledUtc -and [datetime]::Parse([string]$j.ScheduledUtc).ToUniversalTime() -gt [datetime]::UtcNow){continue}
            if($j.NextAttemptUtc -and [datetime]::Parse([string]$j.NextAttemptUtc).ToUniversalTime() -gt [datetime]::UtcNow){continue}
            $job=$j; break
        }
        if(-not $job){if($SinglePass){break};Start-Sleep -Seconds 2;continue}
        try { Invoke-YdrJob $job }
        catch [OperationCanceledException] { Write-YdrLog "Job $($job.Id) was paused/cancelled" }
        catch {
            $reason=Hide-YdrSecret -Text ([string]$_.Exception.Message)
            Write-YdrLog "Job $($job.Id) failed: $reason"
            if($job.Kind -in @('PhotoMove','PhotoRescue')) {
                Update-YdrJob -Id $job.Id -State 'Ошибка' -Details ('Перенос остановлен, проверьте журнал и состояние облака: '+$reason)
            } else { Set-JobRetry -Job $job -Reason $reason }
        }
        if($SinglePass){break}
    }
}
finally { $singleton.ReleaseMutex();$singleton.Dispose() }
