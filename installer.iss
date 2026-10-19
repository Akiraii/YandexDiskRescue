#define AppName "Yandex Disk Rescue"
#define AppVersion "0.9.0"
[Setup]
AppId={{A6780AC8-3804-4A61-8622-40D5EAA78019}
AppName={#AppName}
AppVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\YandexDiskRescue
DefaultGroupName={#AppName}
OutputDir=dist
OutputBaseFilename=YandexDiskRescue-Setup
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=lowest
UninstallDisplayIcon={app}\YandexDiskRescue.exe
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DisableProgramGroupPage=yes

[Files]
Source: "dist\app\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Yandex Disk Rescue"; Filename: "{app}\YandexDiskRescue.exe"
Name: "{userdesktop}\Yandex Disk Rescue"; Filename: "{app}\YandexDiskRescue.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Создать ярлык на рабочем столе"; Flags: unchecked

[Run]
Filename: "{app}\YandexDiskRescue.exe"; Description: "Запустить Yandex Disk Rescue"; Flags: nowait postinstall skipifsilent
