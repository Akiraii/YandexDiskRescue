"""Security regression checks. Source policy only; not network or penetration testing."""
from pathlib import Path
import re
BASE=Path(__file__).resolve().parents[1]
get=lambda p:(BASE/p).read_text(encoding="utf-8")
rclone=get("YandexDiskRescue/Services/RcloneSession.cs")
photos=get("YandexDiskRescue/Services/UnlimitedPhotos.cs")
worker=get("Rescue.Worker/Program.cs")
helper=get("tools/yd.js")
redact=get("YandexDiskRescue/Services/LogRedactor.cs")
assert 'File.Exists(bundled)' in rclone and 'GetEnvironmentVariable("PATH")' not in rclone
assert 'new ProcessStartInfo(node)' in photos and 'node:"node.exe"' not in photos
assert 'LogRedactor.Redact' in rclone and 'LogRedactor.Redact' in photos and 'LogRedactor.Redact' in worker
assert 'action is not ("list" or "move")' in photos
assert "['list', 'move'].includes(action)" in helper
assert '127.0.0.1' in photos and 'disk.yandex.ru' in helper
assert 'DataProtectionScope.CurrentUser' in get("YandexDiskRescue/Services/SecureTokenStore.cs")
assert 'UseShellExecute=false' in rclone
assert '--immutable' in worker and 'RunAsync("copy"' in worker
assert not re.search(r'RunAsync\("(?:sync|delete|purge|move)"',get("YandexDiskRescue/MainWindow.xaml.cs"))
assert 'XmlDocument' not in helper and 'eval(' not in helper
print("[PASS] Executable provenance, logs, authorization, copy-only policies")
print("[LIMIT] CI source checks cannot confirm runtime network destinations or Chrome CDP access")
