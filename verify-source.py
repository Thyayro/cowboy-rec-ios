from pathlib import Path
import json, struct
import re, subprocess
root=Path('cowboy-rec-ios')
for f in root.glob('Sources/*.swift'):
    s=f.read_text(encoding='utf-8-sig')
    assert s.count('{')==s.count('}'), f'{f}: brace mismatch'
    assert 'MWDAT' not in s, f'{f}: unwanted glasses dependency'
cloud=(root/'Sources/CowboyCloud.swift').read_text(encoding='utf-8-sig')
assert '"stabilization": ["enabled": false]' in cloud
assert 'guard me["email"] as? String == owner' in cloud
assert 'result["bytes"] as? Int == size' in cloud
assert 'Ray-Ban' not in cloud and 'Óculos' not in cloud
cam=(root/'Sources/NativeCamera.swift').read_text(encoding='utf-8-sig')
assert 'ramp(toVideoZoomFactor:' in cam
policy=(root/'Sources/CapturePolicy.swift').read_text(encoding='utf-8-sig')
assert 'width: 3840,height: 2160,fps: 60' in policy
assert 'NativeCapturePolicy.select' in cam and '.builtInWideAngleCamera' in cam
assert 'isVideoStabilizationModeSupported' in cam
tracked = subprocess.check_output(['git', '-C', str(root), 'ls-files'], text=True).splitlines()
for name in tracked:
    f = root / name
    if f.suffix == '.png':
        continue
    assert not re.search(r'((?:ghp_|gho_|sk-proj-)[A-Za-z0-9_-]{20,}|-----BEGIN (?:RSA )?PRIVATE KEY-----)',f.read_text(encoding='utf-8-sig')), f
icon=root/'Sources/Assets.xcassets/AppIcon.appiconset'
if icon.exists():
    catalog=json.loads((icon/'Contents.json').read_text())
    png=(icon/catalog['images'][0]['filename']).read_bytes()
    assert png[:8]==b'\x89PNG\r\n\x1a\n' and struct.unpack('>II',png[16:24])==(1024,1024)
    assert png[25]==2, 'iOS app icon must be opaque RGB'
    config=(root/'project.yml').read_text()
    assert 'ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon' in config
    assert 'INFOPLIST_KEY_CFBundleDisplayName: "Cowboy Rec"' in config
print('PASS source structure: native camera/ramp, 4K60 checks, queue ownership/receipt, no duplicate stabilization, no glasses dependency or embedded credentials. Not a Swift compilation.')

app=(root/"Sources/CowboyRecApp.swift").read_text(encoding="utf-8-sig")
assert "NativeCameraSettings(camera:camera" in app, "Native settings must be rendered in the app"
