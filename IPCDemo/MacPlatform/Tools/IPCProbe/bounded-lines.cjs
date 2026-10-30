'use strict';
const {Transform} = require('node:stream');
const {MAX_BYTES} = require('./protocol.cjs');
// Bound memory before readline: readline by itself buffers until the next LF.
class BoundedLines extends Transform {
  constructor(report) { super(); this.parts = []; this.size = 0; this.dropping = false; this.report = report; }
  _transform(chunk, encoding, done) {
    let start = 0;
    for (let i = 0; i < chunk.length; i++) {
      if (chunk[i] !== 10) continue;
      this.append(chunk.subarray(start, i));
      if (!this.dropping) {
        let line = Buffer.concat(this.parts, this.size);
        if (line.at(-1) === 13) line = line.subarray(0, -1);
        try { new TextDecoder('utf-8', {fatal: true}).decode(line); this.push(Buffer.concat([line, Buffer.from('\n')])); }
        catch { this.report('INVALID_UTF8_LINE'); }
      }
      this.parts = []; this.size = 0; this.dropping = false; start = i + 1;
    }
    this.append(chunk.subarray(start));
    done();
  }
  append(part) {
    if (!part.length || this.dropping) return;
    this.size += part.length;
    if (this.size > MAX_BYTES && !(this.size === MAX_BYTES + 1 && part.at(-1) === 13)) {
      this.parts = []; this.size = 0; this.dropping = true; this.report('LINE_TOO_LARGE');
    } else this.parts.push(Buffer.from(part));
  }
  _flush(done) { if (this.size && !this.dropping) this.report('INCOMPLETE_LINE_AT_EOF'); done(); }
}
module.exports = {BoundedLines};
