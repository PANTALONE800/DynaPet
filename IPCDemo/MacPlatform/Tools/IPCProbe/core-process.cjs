'use strict';
const {spawn} = require('node:child_process');
const {EventEmitter} = require('node:events');
const {randomUUID} = require('node:crypto');
const readline = require('node:readline');
const {BoundedLines} = require('./bounded-lines.cjs');
const {decode, encode} = require('./protocol.cjs');

class CoreProcess extends EventEmitter {
  #child; #lines; #filter;
  #pending = new Map(); #writing = Promise.resolve(); #buffered = 0;
  #started = false; #stopping = false; #exited = false; #stopPromise;
  #readyResolve; #readyReject; #startupTimer;
  #lastSeq = 0; #closedResolve;
  constructor(binary, {args = [], env = {}, startupTimeout = 5000} = {}) {
    super(); this.binary = binary; this.args = args; this.env = env; this.startupTimeout = startupTimeout;
    this.closed = new Promise(resolve => { this.#closedResolve = resolve; });
  }
  get pid() { return this.#child?.pid; }
  get exited() { return this.#exited; }
  start() {
    if (this.#started) return Promise.reject(Error('ALREADY_STARTED'));
    this.#started = true;
    const ready = new Promise((resolve, reject) => { this.#readyResolve = resolve; this.#readyReject = reject; });
    try {
      this.#child = spawn(this.binary, this.args, {
        env: {...process.env, ...this.env, DYNAPET_IPC_PARENT_PID: String(process.pid)},
        stdio: ['pipe', 'pipe', 'pipe'], shell: false, windowsHide: true
      });
      this.#child.once('error', () => this.#finish(null, null, 'SPAWN_FAILED'));
      // exit is handled immediately, even if a stream remains open elsewhere.
      this.#child.once('exit', (code, signal) => this.#finish(code, signal, 'CORE_EXITED'));
      this.#child.once('close', () => { this.#lines?.close(); this.#filter?.destroy(); });
      this.#child.stdin.on('error', () => {
        this.#rejectAll(Error('CORE_INPUT_CLOSED'));
        this.emit('fault', 'CORE_INPUT_CLOSED');
        void this.stop().catch(() => {});
      });
      // Diagnostics are drained, but never forwarded verbatim to UI logs: an
      // accidentally logged payload must not leak through this transport.
      this.#child.stderr.on('data', chunk => {
        this.emit('diagnostic', {source: 'core.stderr', bytes: chunk.length});
      });
      this.#filter = new BoundedLines(code => this.emit('protocolFault', code));
      this.#lines = readline.createInterface({input: this.#child.stdout.pipe(this.#filter), crlfDelay: Infinity});
      this.#lines.on('line', line => {
        try { this.#receive(decode(line)); }
        catch { this.emit('protocolFault', 'INVALID_JSON_OR_MESSAGE'); }
      });
      this.#filter.on('error', () => this.emit('protocolFault', 'OUTPUT_STREAM_FAILED'));
      this.#child.stdout.on('error', () => this.emit('protocolFault', 'OUTPUT_STREAM_FAILED'));
      this.#startupTimer = setTimeout(() => {
        this.#readyReject(Error('CORE_STARTUP_TIMEOUT'));
        void this.stop().catch(() => {});
      }, this.startupTimeout);
    } catch { this.#finish(null, null, 'SPAWN_FAILED'); }
    return ready;
  }
  #receive(message) {
    if (message.type === 'event') {
      if (message.body.seq <= this.#lastSeq) { this.emit('protocolFault', 'STALE_EVENT'); return; }
      this.#lastSeq = message.body.seq;
      if (message.body.name === 'core.ready' && !this.#exited) {
        clearTimeout(this.#startupTimer); this.#readyResolve(message);
      }
      this.emit('event', message);
    } else if (message.type === 'response') {
      const pending = this.#pending.get(message.id);
      if (!pending) { this.emit('protocolFault', 'UNKNOWN_RESPONSE_ID'); return; }
      clearTimeout(pending.timer); this.#pending.delete(message.id);
      if (message.body.ok) pending.resolve(message.body.result);
      else { const error = Error(message.body.error.code); error.code = message.body.error.code; pending.reject(error); }
    } else this.emit('protocolFault', 'UNEXPECTED_MESSAGE_TYPE');
  }
  request(method, params = {}, {timeout = 3000} = {}) {
    if (!this.#child || this.#exited || (this.#stopping && method !== 'shutdown')) return Promise.reject(Error('CORE_UNAVAILABLE'));
    if (this.#pending.size >= 128) return Promise.reject(Error('TOO_MANY_REQUESTS'));
    const id = randomUUID();
    let wire;
    try { wire = encode({version: 1, id, type: 'request', body: {method, params}}); }
    catch (error) { return Promise.reject(error); }
    const bytes = Buffer.byteLength(wire);
    if (this.#buffered + bytes > 524_288) return Promise.reject(Error('OUTPUT_QUEUE_FULL'));
    const response = new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.#pending.delete(id); reject(Error('REQUEST_TIMEOUT')); }, timeout);
      this.#pending.set(id, {resolve, reject, timer});
    });
    this.#buffered += bytes;
    const write = this.#writing.then(() => new Promise((resolve, reject) => {
      if (this.#exited || this.#child.stdin.destroyed) return reject(Error('CORE_UNAVAILABLE'));
      // The callback observes pipe backpressure without blocking the UI thread.
      this.#child.stdin.write(wire, error => error ? reject(error) : resolve());
    }));
    this.#writing = write.catch(() => {});
    void write.catch(() => {
      const pending = this.#pending.get(id);
      if (pending) { clearTimeout(pending.timer); this.#pending.delete(id); pending.reject(Error('CORE_INPUT_CLOSED')); }
    }).finally(() => { this.#buffered -= bytes; });
    return response;
  }
  #rejectAll(error) {
    for (const pending of this.#pending.values()) { clearTimeout(pending.timer); pending.reject(error); }
    this.#pending.clear();
  }
  #finish(code, signal, reason) {
    if (this.#exited) return;
    this.#exited = true; clearTimeout(this.#startupTimer);
    this.#readyReject?.(Error(reason)); this.#rejectAll(Error(reason));
    const result = {code, signal, reason, expected: this.#stopping};
    this.#closedResolve(result); this.emit('coreExit', result);
  }
  async #wait(milliseconds) {
    if (this.#exited) return true;
    let timer;
    const result = await Promise.race([
      this.closed.then(() => true),
      new Promise(resolve => { timer = setTimeout(() => resolve(false), milliseconds); })
    ]);
    clearTimeout(timer); return result;
  }
  stop() {
    if (this.#stopPromise) return this.#stopPromise;
    this.#stopPromise = (async () => {
      this.#stopping = true;
      if (!this.#child || this.#exited) return;
      try { await this.request('shutdown', {}, {timeout: 300}); } catch {}
      this.#child.stdin.end();
      if (await this.#wait(400)) return;
      this.#child.kill('SIGTERM');
      if (await this.#wait(700)) return;
      this.#child.kill('SIGKILL');
      if (!await this.#wait(1000)) throw Error('CORE_TERMINATION_TIMEOUT');
    })();
    return this.#stopPromise;
  }
}
module.exports = {CoreProcess};
