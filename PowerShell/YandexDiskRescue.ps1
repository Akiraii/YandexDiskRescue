#requires -Version 5.1
# Native PowerShell 5.1 + WPF GUI. No custom C# or .NET SDK required.
$ErrorActionPreference='Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Yandex Disk Rescue PowerShell GUI работает только в Windows' }
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    throw 'Запускайте приложение через Start-YandexDiskRescue.cmd (PowerShell -STA)'
}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
Import-Module (Join-Path $PSScriptRoot 'YDR.Core.psm1') -Force
Initialize-YdrData
$xamlPath=Join-Path $PSScriptRoot 'MainWindow.xaml'
$reader=[Xml.XmlReader]::Create($xamlPath)
try { $window=[Windows.Markup.XamlReader]::Load($reader) }
finally { $reader.Dispose() }
$names=@('ConnectionStatus','TokenBox','ConnectButton','TokenHelpButton','SaveTokenCheck','SourceBox','DestinationBox',
  'BrowseButton','ListFilesButton','VerifyAfterCopy','AddJobButton','JobsList','PauseButton','ResumeButton',
  'CancelJobButton','VerifyButton','OpenReportButton','PhotoRescueButton','PhotoQuotaButton','PhotoChromeButton',
  'PhotoListButton','PhotoMoveButton','PhotoDownloadButton','PhotoStatus','TransfersSlider','TransfersLabel',
  'BandwidthBox','ScheduleDate','ScheduleTime','DailyCheck','AutostartCheck','RemoveTokenButton',
  'OutputBox','ClearLogButton','JobStatus')
foreach($name in $names) {
    $control=$window.FindName($name)
    if($null -eq $control) { throw "GUI MainWindow.xaml: отсутствует контрол $name" }
    Set-Variable -Name $name -Value $control -Scope Script
}
$script:LastLogText='';$script:LastJobsJson='';$script:LoadedToken=$null
$script:Refreshing=$false

function Message-Ydr([string]$Text,[string]$Title='Yandex Disk Rescue') {
    [void][Windows.MessageBox]::Show($window,$Text,$Title,[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Information)
}
function Error-Ydr([string]$Text) {
    $token=$TokenBox.Password
    $message=Hide-YdrSecret -Text $Text -OAuthToken $token
    $JobStatus.Text='Ошибка'
    [void][Windows.MessageBox]::Show($window,$message,'Ошибка Yandex Disk Rescue',[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Error)
}
function Confirm-Ydr([string]$Text,[string]$Title='Подтверждение') {
    return ([Windows.MessageBox]::Show($window,$Text,$Title,[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Warning) -eq [Windows.MessageBoxResult]::Yes)
}
function Show-YdrLog([string]$Text) {
    $safe=Hide-YdrSecret -Text $Text -OAuthToken $TokenBox.Password
    $OutputBox.AppendText((Get-Date -Format HH:mm:ss)+' '+$safe+[Environment]::NewLine)
    if ($OutputBox.Text.Length -gt 180000) { $OutputBox.Text=$OutputBox.Text.Substring($OutputBox.Text.Length-90000) }
    $OutputBox.ScrollToEnd()
}
function Get-GuiOAuthToken {
    $token=$TokenBox.Password.Trim()
    if (-not $token) { $token=Get-YdrToken }
    if (-not $token) { throw 'Сначала введите OAuth-токен или подключите ранее сохранённый' }
    return $token
}
function Ensure-YdrWorkerToken {
    $saved=Get-YdrToken
    if ($saved) { return }
    $entered=$TokenBox.Password.Trim()
    if (-not $entered) { throw 'Для фонового копирования необходим OAuth-токен' }
    if(-not (Confirm-Ydr 'Сохранить введённый OAuth-токен через Windows DPAPI?\nWorker работает отдельно от окна программы и без сохранённого токена не сможет скачать файлы.' 'Разрешение на сохранение токена')){
        throw 'Фоновое задание не создано: хранение токена не разрешено'
    }
    Save-YdrToken $entered
    $SaveTokenCheck.IsChecked=$true
    Show-YdrLog 'Токен сохранён через DPAPI только для текущего пользователя Windows.'
}
function Refresh-YdrJobs {
    if($script:Refreshing){return}
    $script:Refreshing=$true
    try {
        $selected=if($JobsList.SelectedItem){[string]$JobsList.SelectedItem.Id}else{''}
        $jobs=@(Get-YdrJobs)
        $jobsJson=ConvertTo-Json -InputObject $jobs -Depth 5 -Compress
        if($jobsJson -eq $script:LastJobsJson){return}
        $script:LastJobsJson=$jobsJson
        $JobsList.ItemsSource=$null
        $JobsList.ItemsSource=$jobs
        if($selected){foreach($j in $jobs){if($j.Id -eq $selected){$JobsList.SelectedItem=$j;break}}}
    } catch { Show-YdrLog ('Очередь: '+$_.Exception.Message) }
    finally {$script:Refreshing=$false}
}
function Refresh-YdrLog {
    try {
        $file=Get-YdrDataPath 'log\worker.log'
        if(-not [IO.File]::Exists($file)){return}
        # Only tail; no unbounded log reads, no credentials from raw child output.
        $fs=New-Object IO.FileStream($file,([IO.FileMode]::Open),([IO.FileAccess]::Read),([IO.FileShare]::ReadWrite))
        try {
            $size=$fs.Length; if($size -gt 24000){[void]$fs.Seek(-24000,[IO.SeekOrigin]::End)}
            $sr=New-Object IO.StreamReader($fs,[Text.Encoding]::UTF8,$true)
            try{$content=$sr.ReadToEnd()}finally{$sr.Dispose()}
        }finally{$fs.Dispose()}
        if($content -ne $script:LastLogText){
            $script:LastLogText=$content
            $OutputBox.Text=$content
            $OutputBox.ScrollToEnd()
        }
    } catch { }
}
function Refresh-YdrPhotos {
    try {
        $state=Read-YdrPhotoState
        $PhotoStatus.Text="По списку: $($state.Listed)/$($state.Expected) · Перенесено в облаке: $($state.Moved) · На ПК ещё требуется проверка"
    } catch { $PhotoStatus.Text='Список фотографий ещё не создан или требуется проверка' }
}
function Selected-YdrJob {
    if(-not $JobsList.SelectedItem){throw 'Выберите задание из очереди'}
    return $JobsList.SelectedItem
}
function Queue-Ydr([object]$Job) {
    Ensure-YdrWorkerToken
    Add-YdrJob $Job
    Start-YdrWorker
    $script:LastJobsJson=''
    Refresh-YdrJobs
    Show-YdrLog ('Добавлено задание '+$Job.Id+' · '+$Job.Kind)
}
function Get-GuiDestination {
    $path=$DestinationBox.Text.Trim()
    if(-not $path){throw 'Сначала выберите папку сохранения на ПК'}
    if($path.StartsWith('\\')){throw 'Для безопасности требуется локальный или USB-диск'}
    return [IO.Path]::GetFullPath($path)
}
function Get-GuiSchedule {
    $date=$ScheduleDate.SelectedDate
    $daily=$DailyCheck.IsChecked -eq $true
    if($null -eq $date -and -not $daily){return ''}
    $time=[TimeSpan]::Zero
    $ok=[TimeSpan]::TryParseExact($ScheduleTime.Text.Trim(), 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture,[ref]$time)
    if(-not $ok){throw 'Время запуска укажите в формате ЧЧ:мм'}
    $local=if($null -ne $date){([datetime]$date).Date.Add($time)}else{(Get-Date).Date.Add($time)}
    if($daily -and $local -le (Get-Date)){$local=$local.AddDays(1)}
    return $local.ToUniversalTime().ToString('o')
}

$TokenHelpButton.Add_Click({
    try { Start-Process 'https://yandex.ru/dev/disk/poligon/' | Out-Null }
    catch { Error-Ydr ('Не удалось открыть официальный Полигон Яндекса: '+$_.Exception.Message) }
})
$ConnectButton.Add_Click({
    try {
        $ConnectionStatus.Text='Проверяю…'; $window.Cursor=[Windows.Input.Cursors]::Wait
        $token=Get-GuiOAuthToken
        $result=Invoke-YdrRclone -Verb 'about' -Arguments @('ydr:') -OAuthToken $token
        if($result.ExitCode -ne 0){throw ('rclone: '+(Hide-YdrSecret -Text $result.Output -OAuthToken $token))}
        $ConnectionStatus.Text='Подключено';Show-YdrLog 'Подключение к Яндекс Диску успешно.'
        if($SaveTokenCheck.IsChecked -eq $true){Save-YdrToken $token;Show-YdrLog 'Токен сохранён через DPAPI.'}
    } catch {$ConnectionStatus.Text='Не подключено';Error-Ydr $_.Exception.Message}
    finally{$window.Cursor=[Windows.Input.Cursors]::Arrow}
})
$ListFilesButton.Add_Click({
    try {
        $token=Get-GuiOAuthToken
        $source=Assert-YdrSource $SourceBox.Text
        $window.Cursor=[Windows.Input.Cursors]::Wait
        $r=Invoke-YdrRclone -Verb 'lsf' -Arguments @($source,'--max-depth','2') -OAuthToken $token
        Show-YdrLog ('Облачный список: '+$r.Output)
        if($r.ExitCode -ne 0){throw 'Яндекс не ответил на запрос списка файлов'}
    } catch {Error-Ydr $_.Exception.Message}
    finally {$window.Cursor=[Windows.Input.Cursors]::Arrow}
})
$BrowseButton.Add_Click({
    $dialog=New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description='Выберите папку для резервной копии Яндекс Диска'
    if($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK){$DestinationBox.Text=$dialog.SelectedPath}
    $dialog.Dispose()
})
$AddJobButton.Add_Click({
    try {
        $dest=Get-GuiDestination
        $serial=Get-YdrVolumeSerial $dest
        $src=Assert-YdrSource $SourceBox.Text
        $limit=0
        if(-not [int]::TryParse($BandwidthBox.Text.Trim(),[ref]$limit) -or $limit -lt 0 -or $limit -gt 1048576){throw 'Лимит скорости должен быть от 0 до 1048576 КиБ/с'}
        $schedule=Get-GuiSchedule
        $job=New-YdrJob -Kind 'Copy' -Source $src -Destination $dest -Serial $serial -Transfers ([int]$TransfersSlider.Value) -LimitKiB $limit -Verify ($VerifyAfterCopy.IsChecked -eq $true) -ScheduledUtc $schedule
        if($DailyCheck.IsChecked -eq $true){$job|Add-Member -NotePropertyName RecurringDaily -NotePropertyValue $true}
        Queue-Ydr $job
    }catch{Error-Ydr $_.Exception.Message}
})
$PauseButton.Add_Click({
    try {$job=Selected-YdrJob;Update-YdrJob -Id $job.Id -State 'Приостановлено' -Details 'Остановлено пользователем';$script:LastJobsJson='';Refresh-YdrJobs}
    catch{Error-Ydr $_.Exception.Message}
})
$CancelJobButton.Add_Click({
    try {$job=Selected-YdrJob;if(Confirm-Ydr 'Отменить задание? Уже сохранённые локальные файлы не удаляются.'){
        Update-YdrJob -Id $job.Id -State 'Отменено' -Details 'Отменено пользователем';$script:LastJobsJson='';Refresh-YdrJobs
    }}catch{Error-Ydr $_.Exception.Message}
})
$ResumeButton.Add_Click({
    try {
        $job=Selected-YdrJob
        if($job.VolumeSerial -and (Get-YdrVolumeSerial $job.Destination) -ne $job.VolumeSerial){throw 'Неправильный диск назначения. Возобновление заблокировано'}
        Reset-YdrJob -Id $job.Id
        Start-YdrWorker;$script:LastJobsJson='';Refresh-YdrJobs
    }catch{Error-Ydr $_.Exception.Message}
})
$VerifyButton.Add_Click({
    try {
        $job=Selected-YdrJob
        if($job.Kind -in @('PhotoList','PhotoMove')){throw 'Выберите задание скачивания, а не переноса'}
        $verifyJob=New-YdrJob -Kind 'Check' -Source $job.Source -Destination $job.Destination -Serial $job.VolumeSerial -Verify $true
        Queue-Ydr $verifyJob
    }catch{Error-Ydr $_.Exception.Message}
})
$OpenReportButton.Add_Click({
    try {
        $job=Selected-YdrJob;$root=[IO.Path]::GetFullPath((Get-YdrDataPath 'reports')+'\')
        if(-not $job.Report){throw 'У этого задания ещё нет HTML-отчёта'}
        $path=[IO.Path]::GetFullPath([string]$job.Report)
        if(-not $path.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($path) -ne '.html' -or -not [IO.File]::Exists($path)){throw 'Неверный путь отчёта'}
        Start-Process -FilePath $path | Out-Null
    }catch{Error-Ydr $_.Exception.Message}
})
$PhotoQuotaButton.Add_Click({
    try {
        $window.Cursor=[Windows.Input.Cursors]::Wait;$quota=Get-YdrQuota (Get-GuiOAuthToken)
        $gb=[Math]::Round($quota.Unlimited/1GB,2);$free=[Math]::Round($quota.Free/1GB,2)
        $PhotoStatus.Text="Аккаунт $($quota.Uid) · Безлимит $gb ГиБ · Свободно $free ГиБ · Перенос: $(if($quota.Enough){'достаточно места'}else{'заблокирован — мало места или нулевой объём'})"
    }catch{Error-Ydr $_.Exception.Message}
    finally{$window.Cursor=[Windows.Input.Cursors]::Arrow}
})
$PhotoChromeButton.Add_Click({
    try {
        if(-not (Confirm-Ydr 'Отдельный Chrome будет открыт с локальным отладочным портом CDP. Пока он открыт, другие программы текущего ПК могут получить доступ к браузерной сессии. Используйте только доверенный ПК, затем закройте Chrome.' 'Браузерная безопасность')){return}
        Start-YdrChrome
        Show-YdrLog 'Открылся отдельный Chrome. Войдите в тот же Яндекс ID, что и для OAuth.'
    }catch{Error-Ydr $_.Exception.Message}
})
$PhotoListButton.Add_Click({
    try {
        $job=New-YdrJob -Kind 'PhotoList' -Source '/photounlim' -Destination '' -Serial ''
        Queue-Ydr $job
    }catch{Error-Ydr $_.Exception.Message}
})
$PhotoMoveButton.Add_Click({
    try {
        $state=Read-YdrPhotoState;$quota=Get-YdrQuota (Get-GuiOAuthToken)
        if(-not $quota.Enough){throw 'Свободной обычной квоты недостаточно (необходим запас 5%)'}
        if(-not (Confirm-Ydr "Подтверждаете ПЕРЕМЕЩЕНИЕ $($state.Listed) фотографий из безлимита в обычную папку Диска? Файлы начнут занимать обычную квоту. Это изменение облачных данных!" 'Подтвердить перенос фотографий')){return}
        $job=New-YdrJob -Kind 'PhotoMove' -Source '/photounlim' -Destination '' -Serial ''
        Queue-Ydr $job
    }catch{Error-Ydr $_.Exception.Message}
})
$PhotoDownloadButton.Add_Click({
    try {
        $s=Read-YdrPhotoState
        if($s.Moved -eq 0){throw 'Нет ни одного подтверждённого переноса'}
        $dest=Get-GuiDestination;$serial=Get-YdrVolumeSerial $dest
        if(-not (Confirm-Ydr "Скачать перенесённые фотографии в $dest и проверить по содержимому? Подтверждено переносов: $($s.Moved)/$($s.Listed)." 'Сохранение на ПК')){return}
        $job=New-YdrJob -Kind 'PhotoDownload' -Source 'ydr:Безлимит' -Destination $dest -Serial $serial -Verify $true
        Queue-Ydr $job
    }catch{Error-Ydr $_.Exception.Message}
})
$PhotoRescueButton.Add_Click({
    try {
        $dest=Get-GuiDestination;$serial=Get-YdrVolumeSerial $dest
        $quota=Get-YdrQuota (Get-GuiOAuthToken)
        if(-not $quota.Enough){throw 'Квоты недостаточно для безопасного перемещения безлимита'}
        if(-not (Confirm-Ydr "ЭКСПЕРИМЕНТАЛЬНЫЙ МАСТЕР.\n\nБудет собран список фотографий, затем они будут ПЕРЕМЕЩЕНЫ из безлимита в обычную папку облака «Безлимит» и скачаны в $dest с полной проверкой.\n\nПосле переноса фотографии могут занять существенную квоту. Изменения облака необратимы одной кнопкой. Вы действительно согласны?" 'Внимание: изменение фотографий на Яндексе')){return}
        $job=New-YdrJob -Kind 'PhotoRescue' -Source 'ydr:Безлимит' -Destination $dest -Serial $serial -Verify $true
        Queue-Ydr $job
    }catch{Error-Ydr $_.Exception.Message}
})
$TransfersSlider.Add_ValueChanged({$TransfersLabel.Text='Параллельных потоков: '+[int]$TransfersSlider.Value})
$AutostartCheck.IsChecked=(Get-YdrAutostart)
$AutostartCheck.Add_Click({
    try {Set-YdrAutostart ($AutostartCheck.IsChecked -eq $true);Show-YdrLog 'Настройки автозапуска обновлены.'}
    catch{Error-Ydr $_.Exception.Message}
})
$RemoveTokenButton.Add_Click({
    if(Confirm-Ydr 'Удалить локально сохранённый токен? Фоновые задания потеряют доступ до новой авторизации.'){
        Remove-YdrToken;$TokenBox.Password='';$SaveTokenCheck.IsChecked=$false;$ConnectionStatus.Text='Не подключено';Show-YdrLog 'Сохранённый OAuth-токен удалён.'
    }
})
$ClearLogButton.Add_Click({$OutputBox.Clear();$script:LastLogText=''})

try {
    if(Get-YdrToken){$ConnectionStatus.Text='Есть защищённый токен · нажмите «Проверить»';$SaveTokenCheck.IsChecked=$true}
    Refresh-YdrJobs; Refresh-YdrPhotos;Refresh-YdrLog
} catch { Show-YdrLog ('Инициализация: '+$_.Exception.Message) }
$timer=New-Object Windows.Threading.DispatcherTimer
$timer.Interval=[TimeSpan]::FromSeconds(3)
$timer.Add_Tick({Refresh-YdrJobs;Refresh-YdrLog})
$timer.Start()
$window.Add_Closed({$timer.Stop()})
[void]$window.ShowDialog()
