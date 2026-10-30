'use strict';
const {app, dialog} = require('electron');
const path = require('node:path');
const {CoreProcess} = require('./core-process.cjs');
const {resolveCoreExecutable} = require('./bundled-core.cjs');
let core, quitting = false, allowQuit = false;
function createCore() {
  const binary = process.env.DYNAPET_CORE_BINARY || resolveCoreExecutable(app);
  const child = new CoreProcess(binary, {args:['--ipc']});
  child.on('event', message => {
    console.log('event:', JSON.stringify(message));
    const {name, data, seq} = message.body;
    if (name === 'pet.state_changed') console.log(`[state seq=${seq}] mood=${data.mood} reason=${data.reason} text=${data.text}`);
    if (name === 'play_animation') console.log(`[animation seq=${seq}] ${data.name}`);
    if (name === 'pet.resized') console.log(`[resize seq=${seq}] scale=${data.scale}`);
  });
  child.on('protocolFault', code => console.error('protocol:', code));
  child.on('fault', code => console.error('transport:', code));
  child.on('coreExit', async status => {
    if (quitting || status.expected) return;
    if (process.argv.includes('--smoke-test')) { console.error('CORE_EXITED_DURING_SMOKE_TEST'); app.exit(1); return; }
    // Restart is explicit; pending requests are rejected, never silently replayed.
    const answer = await dialog.showMessageBox({type: 'error', message: 'Swift 核心已退出', detail: '本次连接中的请求已取消。', buttons: ['退出', '重新启动核心'], defaultId: 0, cancelId: 0});
    if (quitting) return;
    if (answer.response === 1) { core = createCore(); void run(core); }
    else app.quit();
  });
  return child;
}
async function run(child) {
  try {
    await child.start();
    if (process.argv.includes('--observe-business')) {
      console.log('Observe: 16 seconds without requests; waiting for an automatic environment state event');
      await new Promise(resolve => setTimeout(resolve, 16000));
    }
    if (process.argv.includes('--mac-window-test')) {
      console.log('pet.touch response:', JSON.stringify(await child.request('pet.touch')));
      await new Promise(resolve => setTimeout(resolve, 350));
      console.log('pet.resize response:', JSON.stringify(await child.request('pet.resize', {scale:1.25})));
    } else console.log('response:', JSON.stringify(await child.request('echo', {text: '来自 Electron 的请求'})));
    if (process.argv.includes('--smoke-test')) app.quit();
  } catch {
    console.error('核心连接未完成');
    if (process.argv.includes('--smoke-test')) { await child.stop().catch(() => {}); app.exit(1); }
  }
}
app.on('before-quit', event => {
  if (allowQuit) return;
  event.preventDefault();
  if (quitting) return;
  quitting = true;
  void (async () => {
    try { await core?.stop(); }
    catch { console.error('CORE_TERMINATION_TIMEOUT'); }
    finally { allowQuit = true; app.quit(); }
  })();
});
app.whenReady().then(() => { core = createCore(); return run(core); });
