'use strict';
const path = require('node:path');
const {CoreProcess} = require('./core-process.cjs');
const binary = process.argv[2] || path.join(__dirname, '../../..', '.build', 'debug', 'ipc-core-demo');
const core = new CoreProcess(binary);
core.on('event', message => console.log('event:', JSON.stringify(message)));
core.on('protocolFault', code => console.error('protocol:', code));
core.on('fault', code => console.error('transport:', code));
core.on('coreExit', status => {
  if (!status.expected) { console.error('Swift 核心异常退出，当前连接已关闭；可重新运行 Demo。'); process.exitCode = 1; }
});
let stopping = false;
async function stop() { if (stopping) return; stopping = true; await core.stop(); }
for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => { void stop().catch(() => { process.exitCode = 1; }); });
(async () => {
  await core.start();
  console.log('response:', JSON.stringify(await core.request('echo', {text: '你好，Swift！'})));
  await stop();
})().catch(async () => { console.error('IPC Demo 失败'); process.exitCode = 1; await stop().catch(() => {}); });
