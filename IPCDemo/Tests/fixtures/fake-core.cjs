'use strict';
const readline = require('node:readline');
const mode = process.argv[2];
let seq = 1;
const ready = () => process.stdout.write(JSON.stringify({version:1,id:'e-1',type:'event',body:{name:'core.ready',seq:seq++,data:{}}}) + '\n');
if (mode === 'bad-output') {
  process.stdout.write('{broken\n' + 'x'.repeat(70_000) + '\n');
  process.stdout.write(Buffer.from([0xff, 10]));
}
ready();
if (mode === 'stubborn') { process.on('SIGTERM', () => {}); process.stdin.resume(); }
readline.createInterface({input:process.stdin}).on('line', line => {
  const request = JSON.parse(line);
  if (mode === 'stubborn') return;
  if (request.body.method === 'crash') { process.kill(process.pid, 'SIGKILL'); return; }
  if (request.body.method === 'hang') return;
  process.stdout.write(JSON.stringify({version:1,id:request.id,type:'response',body:{ok:true,result:request.body.params}}) + '\n');
  if (request.body.method === 'shutdown') process.exit(0);
});
if (mode === 'stubborn') setInterval(() => {}, 1000);
