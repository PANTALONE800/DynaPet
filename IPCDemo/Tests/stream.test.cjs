'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const {spawn, execFileSync} = require('node:child_process');
const {once} = require('node:events');
const readline = require('node:readline');
const {setTimeout: delay} = require('node:timers/promises');
const {CoreProcess} = require('../MacPlatform/Tools/IPCProbe/core-process.cjs');
const {encode, decode} = require('../MacPlatform/Tools/IPCProbe/protocol.cjs');
const binary = process.env.DYNAPET_CORE_BINARY || path.resolve(__dirname, '../.build/debug/ipc-core-demo');
const fake = path.join(__dirname, 'fixtures/fake-core.cjs');
async function until(predicate, timeout = 4000) {
  const deadline = Date.now() + timeout;
  while (!predicate()) { if (Date.now() > deadline) throw Error('TEST_TIMEOUT'); await delay(15); }
}
function raw(t) {
  const child = spawn(binary, {env: {...process.env, DYNAPET_IPC_PARENT_PID: String(process.pid)}, stdio: ['pipe','pipe','pipe']});
  const messages = []; let diagnostics = '';
  readline.createInterface({input:child.stdout}).on('line', line => messages.push(decode(line)));
  child.stderr.on('data', chunk => { diagnostics += chunk; });
  child.stdin.on('error', () => {});
  t.after(async () => { if (child.exitCode === null && child.signalCode === null) { child.kill('SIGKILL'); await once(child, 'exit'); } });
  return {child, messages, diagnostics: () => diagnostics};
}
async function client(t, mode) {
  const core = mode ? new CoreProcess(process.execPath, {args:[fake, mode]}) : new CoreProcess(binary);
  t.after(() => core.stop()); await core.start(); return core;
}
const request = (id, text = '你好') => encode({version:1,id,type:'request',body:{method:'echo',params:{text}}});

test('real Swift event and request-response round trip', async t => {
  const core = new CoreProcess(binary); const events = [];
  core.on('event', event => events.push(event)); t.after(() => core.stop());
  await core.start(); assert.equal(events[0].body.name, 'core.ready');
  assert.deepEqual(await core.request('echo', {text:'你好，Swift！'}), {text:'你好，Swift！'});
});
test('half line is not dispatched until LF; split UTF-8 remains intact', async t => {
  const io = raw(t); await until(() => io.messages.length === 1);
  const wire = Buffer.from(request('partial')); const split = wire.indexOf(Buffer.from('你好')) + 1;
  io.child.stdin.write(wire.subarray(0, split)); await delay(60);
  assert.equal(io.messages.length, 1);
  io.child.stdin.write(wire.subarray(split, -1)); await delay(60);
  assert.equal(io.messages.length, 1);
  io.child.stdin.write('\n'); await until(() => io.messages.length === 2);
  assert.equal(io.messages[1].body.result.text, '你好');
});
test('coalesced requests produce ordered responses with matching IDs', async t => {
  const io = raw(t); await until(() => io.messages.length === 1);
  io.child.stdin.write(request('first') + request('second') + request('third'));
  await until(() => io.messages.length === 4);
  assert.deepEqual(io.messages.slice(1).map(message => message.id), ['first','second','third']);
});
test('Swift discards malformed, invalid and oversized lines and continues', async t => {
  const io = raw(t); await until(() => io.messages.length === 1);
  io.child.stdin.write('{private-invalid-json\n' + '{"version":2}\n' + 'x'.repeat(70_000) + '\n' + request('after-errors'));
  await until(() => io.messages.some(message => message.id === 'after-errors'));
  assert.match(io.diagnostics(), /INVALID_JSON_OR_MESSAGE/); assert.match(io.diagnostics(), /LINE_TOO_LARGE/);
  assert.doesNotMatch(io.diagnostics(), /private-invalid-json/);
});
test('Electron reader discards bad output and recovers through readline', async t => {
  const core = new CoreProcess(process.execPath, {args:[fake,'bad-output']}); const faults = [];
  core.on('protocolFault', code => faults.push(code)); t.after(() => core.stop());
  await core.start(); assert.deepEqual(await core.request('echo', {ok:'yes'}), {ok:'yes'});
  assert(faults.includes('INVALID_JSON_OR_MESSAGE')); assert(faults.includes('LINE_TOO_LARGE')); assert(faults.includes('INVALID_UTF8_LINE'));
});
test('concurrent callers are correlated independently', async t => {
  const core = await client(t);
  const results = await Promise.all(Array.from({length:30}, (_, index) => core.request('echo', {index})));
  assert.deepEqual(results.map(value => value.index), Array.from({length:30}, (_, i) => i));
});
test('application error rejects only its request and connection survives', async t => {
  const core = await client(t);
  await assert.rejects(core.request('unknown'), /METHOD_NOT_FOUND/);
  assert.deepEqual(await core.request('ping'), {pong:true});
});
test('request timeout does not destroy the stream', async t => {
  const core = await client(t, 'normal');
  await assert.rejects(core.request('hang', {}, {timeout:60}), /REQUEST_TIMEOUT/);
  assert.deepEqual(await core.request('echo', {alive:true}), {alive:true});
});
test('normal host shutdown reaps Swift child', async t => {
  const core = await client(t); await core.stop();
  const status = await core.closed; assert.equal(status.expected, true); assert.equal(status.code, 0);
  assert.throws(() => process.kill(core.pid, 0), /ESRCH/);
});
test('stdin EOF triggers graceful SIGTERM cleanup', async t => {
  const io = raw(t); await until(() => io.messages.length === 1);
  const exited = once(io.child, 'exit'); io.child.stdin.end();
  const [code] = await exited; assert.equal(code, 0); assert.match(io.diagnostics(), /STOP_SIGTERM/);
});
test('SIGTERM triggers graceful cleanup instead of abrupt termination', async t => {
  const io = raw(t); await until(() => io.messages.length === 1);
  const exited = once(io.child, 'exit'); io.child.kill('SIGTERM');
  const [code, signal] = await exited; assert.equal(code, 0); assert.equal(signal, null);
  assert.match(io.diagnostics(), /STOP_SIGTERM/);
});
test('abnormal Swift exit is reported and pending request is rejected', async t => {
  const core = await client(t, 'normal'); const exited = once(core, 'coreExit');
  await assert.rejects(core.request('crash'), /CORE_EXITED/);
  const [status] = await exited; assert.equal(status.expected, false); assert.equal(status.signal, 'SIGKILL');
});
test('unresponsive core is escalated to SIGKILL within shutdown deadline', async t => {
  const core = await client(t, 'stubborn'); const start = Date.now(); await core.stop();
  assert.equal((await core.closed).signal, 'SIGKILL'); assert(Date.now()-start < 4000);
});
test('spawn failure rejects startup without an unhandled error event', async t => {
  const core = new CoreProcess('/nonexistent/dynapet-core'); t.after(() => core.stop());
  await assert.rejects(core.start(), /SPAWN_FAILED/); assert.equal((await core.closed).reason, 'SPAWN_FAILED');
});
test('SIGKILL of host terminates Swift even while another process holds stdin open', async t => {
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'dynapet-parent-'));
  const fifo = path.join(folder, 'input'), log = path.join(folder, 'core.log');
  execFileSync('mkfifo', [fifo]); const fd = fs.openSync(fifo, 'r+');
  const parent = spawn(process.execPath, [path.join(__dirname,'fixtures/parent.cjs'),binary,log], {stdio:[fd,'pipe','pipe']});
  let announced = ''; parent.stdout.on('data', chunk => { announced += chunk; }); parent.stderr.resume();
  let corePID;
  t.after(() => { if (corePID) { try { process.kill(corePID,'SIGKILL'); } catch {} } try { parent.kill('SIGKILL'); } catch {} fs.closeSync(fd); fs.rmSync(folder,{recursive:true,force:true}); });
  await until(() => announced.includes('\n')); corePID = JSON.parse(announced.trim()).pid;
  await until(() => fs.existsSync(log) && fs.readFileSync(log,'utf8').includes('core.ready'));
  const parentExit = once(parent, 'exit'); parent.kill('SIGKILL'); await parentExit;
  await until(() => fs.readFileSync(log,'utf8').includes('STOP_SIGTERM'));
  await until(() => { try { process.kill(corePID,0); return false; } catch (error) { return error.code === 'ESRCH'; } });
  corePID = undefined;
});

test('pet.touch and pet.resize route through the real Swift dispatcher', async t => {
  const core = await client(t);
  assert.deepEqual(await core.request('pet.touch'), {accepted:true});
  assert.deepEqual(await core.request('pet.resize', {scale:1.25}), {scale:1.25});
  for (const params of [{scale:true},{scale:0},{scale:1,extra:true}])
    await assert.rejects(core.request('pet.resize', params), /INVALID_PARAMS/);
  await assert.rejects(core.request('pet.touch', {extra:true}), /INVALID_PARAMS/);
  await assert.rejects(core.request('pet.delete'), /METHOD_NOT_FOUND/);
  assert.deepEqual(await core.request('ping'), {pong:true});
});
