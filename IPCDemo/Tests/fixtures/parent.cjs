'use strict';
const fs = require('node:fs');
const {spawn} = require('node:child_process');
const [binary, log] = process.argv.slice(2);
const output = fs.openSync(log, 'a', 0o600);
const core = spawn(binary, {env: {...process.env, DYNAPET_IPC_PARENT_PID: String(process.pid)}, stdio: ['inherit', output, output]});
core.on('error', () => process.exit(2));
process.stdout.write(JSON.stringify({pid: core.pid}) + '\n');
setInterval(() => {}, 1000);
