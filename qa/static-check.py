"""Source-level sanity checks only. Does NOT replace compilation, end-to-end or security audit."""
from pathlib import Path
from xml.etree import ElementTree as ET
import re, subprocess, hashlib
base=Path(__file__).resolve().parents[1]
for file in [*base.rglob('*.xaml'),*base.rglob('*.csproj')]:
    ET.parse(file)
    print('[PASS] XML:',file.relative_to(base))
forbidden=re.compile(r'RunAsync\("(?:sync|delete|purge|move)"',re.I)
for file in base.rglob('*.cs'):
    assert not forbidden.search(file.read_text(encoding='utf-8')),f'unsafe operation in {file}'
print('[PASS] No dangerous rclone verbs in direct runner calls')
xaml=(base/'YandexDiskRescue/MainWindow.xaml').read_text(encoding='utf-8')
cs=(base/'YandexDiskRescue/MainWindow.xaml.cs').read_text(encoding='utf-8')
methods=set(re.findall(r'\b(?:private|public)\s+(?:async\s+)?(?:void|Task<bool>|Task<int>|Task|int|string)\s+(\w+)\s*\(',cs))
handlers=set(re.findall(r'\b(?:Click|Checked|Unchecked|ValueChanged|PasswordChanged)="([A-Za-z]\w+)"',xaml))
assert handlers<=methods,f'Missing event handlers: {handlers-methods}'
print('[PASS] WPF event handlers:',len(handlers))
helper=base/'tools/yd.js'
hash=hashlib.sha256(helper.read_bytes()).hexdigest().upper()
assert hash in (base/'YandexDiskRescue/Services/UnlimitedPhotos.cs').read_text(encoding='utf-8')
print('[PASS] Pinned yd.js SHA256:',hash)
subprocess.run(['node','--check',str(helper)],check=True)
print('[PASS] Node.js syntax')
print('Source structure verified. Windows compilation, network and Yandex API behaviour are NOT verified.')
