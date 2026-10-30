#!/usr/bin/env python3
"""Package an already built/signed complete native app and verify its ZIP roundtrip."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--public-demo', action='store_true')
args = parser.parse_args()
source = args.app.resolve()
info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'io.github.pantalone800.dynapet'
assert info['LSUIElement'] is True
version = info['CFBundleShortVersionString']
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(source)], check=True)
arch = subprocess.check_output(['xcrun', 'lipo', '-archs', str(source / 'Contents/MacOS/DynaPet')], text=True).strip()
assert arch == 'arm64', 'This release package is labelled Apple Silicon only'
dependencies = subprocess.check_output(['xcrun', 'otool', '-L', str(source / 'Contents/MacOS/DynaPet')], text=True)
assert not any('/Users/' in line or '/private/tmp/' in line for line in dependencies.splitlines()[1:])
assert len(list((source / 'Contents/Resources/DemoTheme').glob('*.png'))) == 11
for path in source.rglob('*'):
    assert not any(word in path.name.lower() for word in ['diagnostic', 'capabilities', 'settings.json', '.env', 'privatekey']), path.name
stage = Path(tempfile.mkdtemp(prefix='dynapet-mac-final-'))
name = f'DynaPet-macOS-AppleSilicon-v{version}-public-demo' if args.public_demo else f'DynaPet-macOS-AppleSilicon-v{version}-完整版'
folder = stage / name
folder.mkdir()
subprocess.run(['ditto', '--noqtn', str(source), str(folder / 'DynaPet.app')], check=True)
if args.public_demo:
    notice = (repo / 'DemoTheme/NOTICE.md').read_text()
    assert 'CC0-1.0' in notice and 'no historical character images' in notice
    subprocess.run(['ditto', str(repo / 'TestThemes/MinimalGif'), str(folder / '测试主题/MinimalGif')], check=True)
(folder / '安装与使用说明.txt').write_text((repo / 'DynaPet/使用说明.md').read_text(encoding='utf-8'), encoding='utf-8-sig')
notice_files = ['LICENSE', 'LICENSE_SCOPE.md', 'THIRD_PARTY_NOTICES.md', 'PRIVACY.md', 'SECURITY.md']
for filename in notice_files:
    (folder / filename).write_bytes((repo / filename).read_bytes())

out = repo / '分享发布' / (name + '.zip')
out.parent.mkdir(exist_ok=True)
subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(folder), str(out)], check=True)
verify = Path(tempfile.mkdtemp(prefix='dynapet-mac-roundtrip-'))
subprocess.run(['ditto', '-x', '-k', str(out), str(verify)], check=True)
app = verify / name / 'DynaPet.app'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
def manifest(root):
    return {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*') if p.is_file()}
assert manifest(source) == manifest(app)
assert sorted(p.name for p in (verify / name).iterdir()) == sorted(['DynaPet.app', '安装与使用说明.txt'] + notice_files + (['测试主题'] if args.public_demo else []))
checksum = hashlib.sha256(out.read_bytes()).hexdigest()
out.with_suffix('.zip.sha256').write_text(checksum + '  ' + out.name + '\n')
report = dict(artifact=out.name, version=version, arch=arch, sha256=checksum, bytes=out.stat().st_size,
              signing='ad-hoc; not notarized', zipRoundtrip=True, nativeGuiStarted=False, files=manifest(app))
report_path = repo / 'IPCDemo/.build' / f'mac-full-{version}-package-verification.json'
report_path.parent.mkdir(exist_ok=True)
report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2))
print(json.dumps({k: v for k, v in report.items() if k != 'files'}, ensure_ascii=False, indent=2))
