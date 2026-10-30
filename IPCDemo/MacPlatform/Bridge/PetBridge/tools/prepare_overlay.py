from pathlib import Path
import json
import sys
root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
original = Path('/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap')
roots = []
if original.exists() and original.with_name('bridging.modulemap').exists():
    empty = root / 'empty.modulemap'
    empty.write_text('// Local duplicate-module workaround; system files untouched.\n')
    roots.append({'type': 'file', 'name': str(original), 'external-contents': str(empty)})
(root / 'toolchain-overlay.json').write_text(json.dumps({'version': 0, 'roots': roots}))
