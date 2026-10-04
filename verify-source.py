from pathlib import Path
import re
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
assert 'ramp(toVideoZoomFactor:' in cam and '3840' in cam and '2160' in cam
assert 'isVideoStabilizationModeSupported' in cam
for f in root.rglob('*'):
    if f.is_file() and ".git" not in f.parts:
        assert not re.search(r'((?:ghp_|gho_|sk-proj-)[A-Za-z0-9_-]{20,}|-----BEGIN (?:RSA )?PRIVATE KEY-----)',f.read_text(encoding='utf-8-sig')), f
print('PASS source structure: native camera/ramp, 4K60 checks, queue ownership/receipt, no duplicate stabilization, no glasses dependency or embedded credentials. Not a Swift compilation.')
