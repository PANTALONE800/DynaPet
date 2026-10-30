'use strict';
const MAX_BYTES = 65_536;
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const keys = (value, names) => object(value) && Object.keys(value).length === names.length && names.every(name => Object.hasOwn(value, name));
const name = value => typeof value === 'string' && /^[A-Za-z][A-Za-z0-9_.-]{0,63}$/.test(value);
function validate(message) {
  if (!keys(message, ['version', 'id', 'type', 'body']) || message.version !== 1 || typeof message.id !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(message.id) || !object(message.body)) throw Error('INVALID_ENVELOPE');
  const b = message.body;
  let valid = false;
  switch (message.type) {
    case 'request': valid = keys(b, ['method', 'params']) && name(b.method) && object(b.params); break;
    case 'response': valid = b.ok === true ? keys(b, ['ok', 'result']) && object(b.result) : b.ok === false && keys(b, ['ok', 'error']) && keys(b.error, ['code', 'message']) && name(b.error.code) && typeof b.error.message === 'string' && Buffer.byteLength(b.error.message) <= 2048; break;
    case 'event': valid = keys(b, ['name', 'seq', 'data']) && name(b.name) && Number.isSafeInteger(b.seq) && b.seq >= 1 && object(b.data); break;
  }
  if (!valid) throw Error('INVALID_MESSAGE_BODY');
  return message;
}
function decode(line) {
  if (Buffer.byteLength(line) > MAX_BYTES) throw Error('MESSAGE_TOO_LARGE');
  return validate(JSON.parse(line));
}
function encode(message) {
  validate(message);
  const data = JSON.stringify(message);
  if (Buffer.byteLength(data) > MAX_BYTES) throw Error('MESSAGE_TOO_LARGE');
  // Validate the wire form too: undefined, NaN, cycles, and custom toJSON must
  // not silently change a message after the initial object validation.
  decode(data);
  return data + '\n';
}
module.exports = {MAX_BYTES, validate, decode, encode};
