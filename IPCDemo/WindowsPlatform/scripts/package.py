#!/usr/bin/env python3
"""Build, test, validate and ZIP the standalone Windows app on macOS or Windows."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import zipfile
import zlib
import xml.etree.ElementTree as ET

repo = Path(__file__).resolve().parents[3]
platform = repo / 'IPCDemo/WindowsPlatform'
parser = argparse.ArgumentParser()
parser.add_argument('--dotnet', default=os.environ.get('DYNAPET_DOTNET'))
parser.add_argument('--public-demo', action='store_true', help='Label a build from a clean geometric-demo source export')
parser.add_argument('--no-restore', action='store_true')
parser.add_argument('--package-existing', action='store_true', help='Revalidate and package an existing matching publish; no build or test rerun')
args = parser.parse_args()
dotnet = args.dotnet or shutil.which('dotnet')
if not dotnet:
    local = repo / '.build/dotnet10/dotnet'
    if local.is_file():
        dotnet = str(local)
if not dotnet:
    raise SystemExit('Install .NET SDK 10 or set DYNAPET_DOTNET to its executable.')
env = dict(os.environ, DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_NOLOGO='1')
env.setdefault('DOTNET_CLI_HOME', str(repo / '.build/dotnet10-home'))
env.setdefault('NUGET_PACKAGES', str(repo / '.build/nuget'))

def run(*arguments):
    subprocess.run([dotnet, *map(str, arguments)], check=True, cwd=platform, env=env)

flags = ['--no-restore'] if args.no_restore else []
if not args.package_existing:
    run('run', '--project', platform / 'Tests/DynaPet.Core.Checks.csproj', '-c', 'Release', *flags, '--', repo)
version = ET.parse(platform / 'App/DynaPet.Windows.csproj').findtext('./PropertyGroup/Version')
assert version
publish = repo / 'IPCDemo/dist/windows' / ('v' + version) / 'win-x64'
if not args.package_existing:
    run('publish', platform / 'App/DynaPet.Windows.csproj', '-c', 'Release', '-r', 'win-x64',
        '--self-contained', 'true', '-o', publish, *flags)
# Preserve upstream runtime notices without adding clutter to the visible file list.
notices = (repo / 'THIRD_PARTY_NOTICES.md').read_text(encoding='utf-8')
(publish / '使用说明.txt').write_text((platform / '使用说明.txt').read_text(encoding='utf-8'), encoding='utf-8-sig')
notice_files = ['LICENSE', 'LICENSE_SCOPE.md', 'THIRD_PARTY_NOTICES.md', 'PRIVACY.md', 'SECURITY.md']
for filename in notice_files:
    shutil.copy2(repo / filename, publish / filename)

exe = (publish / 'DynaPet.exe').read_bytes()
pe = struct.unpack_from('<I', exe, 0x3c)[0]
assert exe[pe:pe+4] == b'PE\0\0'
assert struct.unpack_from('<H', exe, pe + 4)[0] == 0x8664, 'Expected Windows x64 machine'
assert struct.unpack_from('<H', exe, pe + 24 + 68)[0] == 2, 'Expected GUI subsystem (no console)'
# .NET single-file format (manifest version 6), verified from the actual .NET 10 bundle
# Microsoft.NET.HostModel/Bundle/{Manifest,FileEntry}.cs.
magic = bytes.fromhex('8b1202b96a612038727b930214d7a03213f5b9e6efae3318ee3b2dce24b36aae')
marker = exe.find(magic)
assert marker >= 8, 'Missing single-file bundle marker'
header = struct.unpack_from('<Q', exe, marker - 8)[0]
assert 0 < header < len(exe)
reader = io.BytesIO(exe)
reader.seek(header)
major, minor, entry_count = struct.unpack('<III', reader.read(12))
assert major == 6, 'Unexpected .NET bundle format'
def read_string():
    length, shift = 0, 0
    while True:
        byte = reader.read(1)[0]
        length |= (byte & 127) << shift
        if byte < 128:
            break
        shift += 7
        assert shift <= 28
    return reader.read(length).decode('utf-8')
read_string()  # bundle ID
reader.read(40)  # deps/runtimeconfig locations and flags
entries = {}
for _ in range(entry_count):
    offset, size, compressed_size = struct.unpack('<qqq', reader.read(24))
    file_type = reader.read(1)[0]
    name = read_string()
    assert offset >= 0 and size > 0 and offset + (compressed_size or size) <= header
    entries[name] = (offset, size, compressed_size)
def bundled(name):
    offset, size, compressed = entries[name]
    data = exe[offset:offset + (compressed or size)]
    if compressed:
        data = zlib.decompress(data, -15)
    assert len(data) == size
    return data
runtime = json.loads(bundled('DynaPet.runtimeconfig.json'))['runtimeOptions']
assert 'includedFrameworks' in runtime and not runtime.get('frameworks'), 'Expected self-contained runtime'
assert all(f['version'].startswith('10.0.') for f in runtime['includedFrameworks']), 'A .NET 8/9 runtime must not slip into this release'
# Windows singlefilehost statically links CoreCLR/HostFxr into its PE.
for required in ['System.Private.CoreLib.dll', 'PresentationFramework.dll', 'wpfgfx_cor3.dll', 'DynaPet.Core.dll']:
    assert required in entries, f'Missing bundled runtime: {required}'
assembly = bundled('DynaPet.dll')
assert assembly == (platform / 'App/bin/Release/net10.0-windows10.0.19041.0/win-x64/DynaPet.dll').read_bytes()
assets = repo / 'DemoTheme'
assert len(list(assets.glob('*.png'))) == 11
for path in assets.glob('*.png'):
    assert ('DynaPet.DemoTheme.' + path.name).encode() in assembly
    assert path.read_bytes() in assembly, f'Missing embedded asset: {path.name}'
    width, height = struct.unpack_from('>II', path.read_bytes(), 16)
    assert width % 3 == 0 and height > 0
assert b'DynaPet.Icon' in assembly and (platform / 'App/DynaPet.ico').read_bytes() in assembly
assert (publish / '使用说明.txt').is_file()

release = repo / '分享发布'
release.mkdir(exist_ok=True)
name = 'DynaPet-Windows-x64-v' + version
if args.public_demo:
    notice = (repo / 'DemoTheme/NOTICE.md').read_text()
    assert 'CC0-1.0' in notice and 'no historical character images' in notice, 'Public demo requires the clean source export'
    name += '-public-demo'
archive = release / (name + '.zip')
files = [publish / 'DynaPet.exe', publish / '使用说明.txt'] + [publish / filename for filename in notice_files]
assert {p.name for p in publish.iterdir() if p.suffix != '.pdb' and p.name != 'self-test-result.txt'} == {p.name for p in files}, 'Unexpected loose runtime files'
contents = {path.relative_to(publish).as_posix(): path for path in files}
# Include the same portable animated theme used by both platform implementations.
for path in sorted((repo / 'TestThemes/MinimalGif').iterdir()):
    if path.is_file():
        contents['测试主题/MinimalGif/' + path.name] = path
manifest = {relative: hashlib.sha256(path.read_bytes()).hexdigest() for relative, path in contents.items()}
with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as output:
    for relative, path in contents.items():
        output.write(path, name + '/' + relative)
with zipfile.ZipFile(archive) as check:
    assert check.testzip() is None
    for relative, digest in manifest.items():
        assert hashlib.sha256(check.read(name + '/' + relative)).hexdigest() == digest
checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
archive.with_suffix('.zip.sha256').write_text(checksum + '  ' + archive.name + '\n')
report = {
    'artifact': archive.name, 'sha256': checksum, 'bytes': archive.stat().st_size,
    'machine': 'x64', 'subsystem': 'Windows GUI', 'selfContained': True,
    'singleFile': True, 'bundledFiles': entry_count, 'visibleFiles': len(contents), 'animations': 11, 'assetFrames': 33, 'messaging': False,
    'checks': 'C# behavior and OCR pipe tests, PE headers, single-file manifest, embedded runtime and exact PNG/icon bytes, ZIP CRC and SHA256 roundtrip',
    'runtimeFrameworks': runtime['includedFrameworks'], 'sdkRequired': '10.0.403',
    'windowsGuiTested': False, 'windowsNativeGifTested': False,
    'dynamicGifThemes': True, 'demoTheme': '测试主题/MinimalGif', 'files': manifest,
}
(repo / 'IPCDemo/dist/windows/package-verification.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
print(f'PACKAGE VERIFIED: {archive}\nSIZE: {archive.stat().st_size / 1024 / 1024:.1f} MiB\nSHA256: {checksum}')
