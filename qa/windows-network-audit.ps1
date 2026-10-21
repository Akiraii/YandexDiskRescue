# Run ONLY on a trusted Windows 10/11 PC during a controlled test.
# Captures connection metadata, not packet payloads, OAuth tokens, or command lines.
param([ValidateRange(10,1800)][int]$Seconds=120,[ValidateRange(1,10)][int]$Interval=2)
$ErrorActionPreference='Stop'
$names=@('YandexDiskRescue.exe','Rescue.Worker.exe','node.exe','rclone.exe')
$folder=Join-Path $env:LOCALAPPDATA 'YandexDiskRescue\security-audit'
New-Item -ItemType Directory -Force -Path $folder | Out-Null
$file=Join-Path $folder ('connections-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.csv')
$records=New-Object System.Collections.Generic.List[object]
$end=(Get-Date).AddSeconds($Seconds)
while((Get-Date) -lt $end) {
  $snapshot=Get-CimInstance Win32_Process
  $roots=@($snapshot | Where-Object { 
    ($names -contains $_.Name) -or
    ($_.Name -eq 'chrome.exe' -and $_.CommandLine -like '*chrome-unlimited-profile*')
  })
  $ids=New-Object 'System.Collections.Generic.HashSet[int]'
  foreach($p in $roots) { [void]$ids.Add([int]$p.ProcessId) }
  $changed=$true
  while($changed) {
    $changed=$false
    foreach($p in $snapshot) {
      if($ids.Contains([int]$p.ParentProcessId) -and $ids.Add([int]$p.ProcessId)) {$changed=$true}
    }
  }
  $pmap=@{};foreach($p in $snapshot){$pmap[[int]$p.ProcessId]=$p.Name}
  foreach($c in @(Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
    if($ids.Contains([int]$c.OwningProcess)) {
      $records.Add([pscustomobject]@{
        Time=(Get-Date).ToString('o'); Process=$pmap[[int]$c.OwningProcess];
        PID=[int]$c.OwningProcess; RemoteIP=$c.RemoteAddress;RemotePort=$c.RemotePort;
        LocalPort=$c.LocalPort;State=[string]$c.State
      })
    }
  }
  Start-Sleep -Seconds $Interval
}
$records | Sort-Object Time,Process,RemoteIP,RemotePort -Unique | Export-Csv $file -Encoding UTF8 -NoTypeInformation
Write-Host "Только сетевые метаданные (не пакеты) сохранены: $file"
Write-Host 'Отсутствие подозрительных IP в файле НЕ доказывает отсутствие утечки.'
