# Build and package the offline-capable user distribution on Windows 10/11.
# Requires .NET 8 SDK, Node.js/npm, rclone.exe (from official distribution) and internet on BUILD machine.
# End users of dist/YandexDiskRescue-Portable.zip need none of those separately.
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$tools = Join-Path $root 'tools'
$dist = Join-Path $root 'dist'
$app = Join-Path $dist 'app'
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw 'На машине сборки не установлен .NET 8 SDK' }
$node = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
if (-not $node) { throw 'На машине сборки не установлен Node.js (нужен node.exe)' }
$npm = (Get-Command npm.cmd -ErrorAction SilentlyContinue).Source
if (-not $npm) { throw 'На машине сборки не найден npm.cmd' }
$rclone = Join-Path $tools 'rclone.exe'
if (-not (Test-Path $rclone)) {
    $systemRclone = Get-Command rclone.exe -ErrorAction SilentlyContinue
    if (-not $systemRclone) { throw 'Нужен проверенный rclone.exe в tools либо PATH для упаковки. Не скачивайте неизвестные бинарники.' }
    $rclone = $systemRclone.Source
}
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
New-Item -ItemType Directory -Force -Path $app | Out-Null
Write-Host 'Установка зафиксированной зависимости playwright-core на машине сборки...'
Push-Location $tools
try {
    if (-not (Test-Path 'package-lock.json')) {
        & $npm install --package-lock-only --ignore-scripts --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { throw 'npm lock generation failed' }
    }
    & $npm ci --omit=dev --ignore-scripts --no-audit --no-fund
    if ($LASTEXITCODE -ne 0) { throw 'npm ci failed' }
} finally { Pop-Location }
Write-Host 'Публикация GUI...'
& dotnet publish (Join-Path $root 'YandexDiskRescue\YandexDiskRescue.csproj') -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o $app
if ($LASTEXITCODE -ne 0) { throw 'WPF publish failed' }
Write-Host 'Публикация фонового исполнителя...'
& dotnet publish (Join-Path $root 'Rescue.Worker\Rescue.Worker.csproj') -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o $app
if ($LASTEXITCODE -ne 0) { throw 'Worker publish failed' }
$appTools = Join-Path $app 'tools'
New-Item -ItemType Directory -Force -Path $appTools | Out-Null
Copy-Item (Join-Path $tools 'yd.js') $appTools
Copy-Item (Join-Path $tools 'package.json') $appTools
Copy-Item (Join-Path $tools 'package-lock.json') $appTools
Copy-Item (Join-Path $tools 'node_modules') $appTools -Recurse
Copy-Item $node (Join-Path $appTools 'node.exe')
Copy-Item $rclone (Join-Path $appTools 'rclone.exe')
Copy-Item (Join-Path $root 'LICENSE-UPSTREAM.txt') $app
Copy-Item (Join-Path $root 'README.md') $app
if (-not (Test-Path (Join-Path $app 'YandexDiskRescue.exe'))) {throw 'Нет исполняемого файла GUI'}
if (-not (Test-Path (Join-Path $app 'Rescue.Worker.exe'))) {throw 'Нет исполняемого файла worker'}
Get-ChildItem $app -Recurse -File | ForEach-Object {
    [pscustomobject]@{Path=$_.FullName.Substring($app.Length+1); SHA256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash}
} | Export-Csv (Join-Path $dist 'SHA256-files.csv') -NoTypeInformation -Encoding UTF8
Compress-Archive -Path (Join-Path $app '*') -DestinationPath (Join-Path $dist 'YandexDiskRescue-Portable.zip') -CompressionLevel Optimal
$inno = @(
    'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
    'C:\Program Files\Inno Setup 6\ISCC.exe'
) | Where-Object {Test-Path $_} | Select-Object -First 1
if ($inno) {
    & $inno (Join-Path $root 'installer.iss')
    if ($LASTEXITCODE -ne 0) {throw 'Inno Setup failed'}
} else {Write-Warning 'Inno Setup 6 не найден: создан Portable, установщик не собран.'}
Write-Host "Итоги в $dist. Проведите Windows и сетевые испытания до использования с реальными личными файлами."
