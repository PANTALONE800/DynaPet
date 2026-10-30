from pathlib import Path
import json
import os
import platform
import plistlib
import shutil
import subprocess
import tempfile
import time

project = Path(__file__).resolve().parent.parent
arch = platform.machine()
app = project / 'dist' / arch / 'DynaPet.app'
logs = []

def run(args, **kwargs):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=20, **kwargs)
    logs.append('$ ' + ' '.join(str(a) for a in args) + '\n' + result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f'Command failed ({result.returncode}): {args}\n{result.stderr}')
    return result

with (app/'Contents/Info.plist').open('rb') as source:
    info = plistlib.load(source)
assert info['CFBundleExecutable'] == 'DynaPet'
assert info['LSUIElement'] is True
assert (app/'Contents/Resources'/info['CFBundleIconFile']).is_file()
for source in [app/'Contents/MacOS/DynaPet', *(app/'Contents/Frameworks').glob('*.dylib')]:
    assert arch in run(['xcrun', 'lipo', '-info', source]).stdout
run(['codesign', '--verify', '--deep', '--strict', '--verbose=2', app])
# Verify every non-system @rpath dependency resolves inside the bundle.
for source in [app/'Contents/MacOS/DynaPet', *(app/'Contents/Frameworks').glob('*.dylib')]:
    dependencies = run(['xcrun', 'otool', '-L', source]).stdout
    for line in dependencies.splitlines()[1:]:
        dependency = line.strip().split(' (')[0]
        if dependency.startswith('@rpath/'):
            assert (app/'Contents/Frameworks'/dependency.removeprefix('@rpath/')).is_file(), dependency
        else:
            assert dependency.startswith('/usr/lib/') or dependency.startswith('/System/Library/'), dependency

with tempfile.TemporaryDirectory(prefix='DynaPet package with spaces ') as folder:
    folder = Path(folder)
    relocated = folder/'DynaPet.app'
    run(['ditto', '--norsrc', app, relocated])
    run(['codesign', '--verify', '--deep', '--strict', relocated])
    executable = relocated/'Contents/MacOS/DynaPet'
    env = dict(os.environ)
    for key in ['DYLD_LIBRARY_PATH','DYLD_FALLBACK_LIBRARY_PATH','DYNAPET_IPC_PARENT_PID','DYNAPET_MAC_ASSETS']:
        env.pop(key, None)
    bridge = run([executable, '--bridge-self-test'], cwd='/tmp', env=env)
    assert 'live_handles=0 live_native_windows=0' in bridge.stdout
    # No host, no stdin and no shell. The native application must remain alive.
    report = folder/'standalone-report.json'
    env['DYNAPET_MAC_REPORT'] = str(report)
    child = subprocess.Popen([str(executable)], cwd='/tmp', env=env,
                             stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        time.sleep(2)
        assert child.poll() is None, 'Standalone GUI exited when stdin was closed'
        child.terminate()
        output, errors = child.communicate(timeout=6)
        logs.append(f'Standalone PID {child.pid}: exit={child.returncode}\n{output}{errors}')
        assert child.returncode == 0
        state = json.loads(report.read_text())
        assert state['visible'] and state['bridgeLinked'] and not state['ipcEnabled']
        assert state['level'] == state['floatingLevel']
    finally:
        if child.poll() is None:
            child.kill(); child.wait()

verification = project/'verification'
verification.mkdir(exist_ok=True)
(verification/'app-package.log').write_text('\n'.join(logs))
(verification/'app-package.json').write_text(json.dumps({
    'app': str(app), 'architecture': arch, 'signature': 'ad-hoc verified',
    'relocatedWithSpaces': True, 'noDYLDEnvironmentRequired': True,
    'bundledBridgeCall': 'passed', 'standaloneWithClosedStdin': 'passed',
    'standaloneChildExitedCleanly': True,
    'frameworks': sorted(p.name for p in (app/'Contents/Frameworks').glob('*.dylib'))
}, ensure_ascii=False, indent=2)+'\n')
print('PASS: signed bundle, relocated rpath/bridge call, native standalone with closed stdin, clean shutdown')
