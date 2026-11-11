# Yandex Disk Rescue — PowerShell Edition (основная версия)

**Windows 10/11 x64 · PowerShell 5.1 · WPF GUI · без C#-сборки.**

Новый основной проект находится в каталоге [PowerShell](PowerShell/). Для запуска скачайте артефакт **YDR-PowerShell-Portable** из [GitHub Actions](https://github.com/Akiraii/YandexDiskRescue/actions/workflows/powershell-windows.yml), распакуйте ZIP и откройте `Start-YandexDiskRescue.cmd`.

Программа предоставляет GUI на PowerShell: OAuth Яндекса, копирование rclone, локальную очередь, фоновый PS worker, паузу и возобновление, проверку содержимого, локальные HTML/CSV-отчёты, режим фото из безлимита с обязательным подтверждением переноса. Для режима безлимита в комплект входят Node.js и проверенный `yd.js`; `rclone.exe` также входит в Portable ZIP.

Полная инструкция: [PowerShell/README.md](PowerShell/README.md).

**Безопасность:** перенос через внутренний API Яндекса остаётся экспериментальным. Испытайте сначала на отдельном тестовом аккаунте. Ранее созданная C# версия и её исходники сохранены в репозитории для истории; старая CI-сборка запускается только вручную. Новая основная поставка — PowerShell Portable.

