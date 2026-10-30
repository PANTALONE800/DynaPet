'use strict';
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const {spawn} = require('node:child_process');
const {setTimeout: delay} = require('node:timers/promises');
const {createHash} = require('node:crypto');
const root = path.resolve(__dirname,'..');
const electron = process.env.DYNAPET_ELECTRON_BINARY || path.join(root,'../ACFriends/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron');
const binary = path.join(root,'dist',process.arch,'DynaPet.app/Contents/MacOS/DynaPet');
const verification = path.join(root,'verification');fs.mkdirSync(verification,{recursive:true});
const report = path.join(root,'.build/mac-verification/electron-business-window.json');
fs.mkdirSync(path.dirname(report),{recursive:true});fs.rmSync(report,{force:true});
const env={...process.env,DYNAPET_CORE_BINARY:binary,DYNAPET_MAC_REPORT:report};delete env.ELECTRON_RUN_AS_NODE;
const child=spawn(electron,[path.join(root,'MacPlatform/Tools/IPCProbe/electron-demo.cjs'),'--mac-window-test','--observe-business','--smoke-test'],{env,stdio:['ignore','pipe','pipe']});
let output='',errors='';
child.stdout.on('data',chunk=>{output+=chunk;process.stdout.write(chunk);});
child.stderr.on('data',chunk=>{errors+=chunk;process.stderr.write(chunk);});
const timeout=setTimeout(()=>child.kill('SIGTERM'),35_000);
child.on('error',error=>{clearTimeout(timeout);console.error(error.message);process.exitCode=1;});
child.on('close',async code=>{
  clearTimeout(timeout);
  try{
    fs.writeFileSync(path.join(verification,'electron-business.log'),output+(errors?'\n[stderr]\n'+errors:''));
    assert.equal(code,0);
    const events=output.split('\n').filter(line=>line.startsWith('event: ')).map(line=>JSON.parse(line.slice(7)));
    assert.deepEqual(events.map(message=>message.body.seq),events.map((_,index)=>index+1));
    assert(events.some(message=>message.body.name==='pet.state_changed'&&message.body.data.reason==='startup'));
    assert(events.some(message=>message.body.name==='pet.state_changed'&&message.body.data.reason==='environment'));
    assert(events.some(message=>message.body.name==='pet.state_changed'&&message.body.data.reason==='touch'&&message.body.data.mood==='happy'));
    assert(events.some(message=>message.body.name==='play_animation'&&message.body.data.name==='happy'));
    assert(events.some(message=>message.body.name==='pet.resized'&&message.body.data.scale===1.25));
    assert(output.includes('pet.touch response: {"accepted":true}'));
    assert(output.includes('pet.resize response: {"scale":1.25}'));
    const window=JSON.parse(fs.readFileSync(report,'utf8'));
    assert.equal(window.animation,'happy');assert.equal(window.width,300);assert.equal(window.height,325);
    assert.equal(window.appliedOnMainThread,true);assert.equal(window.level,window.floatingLevel);
    const corePID=events.find(message=>message.body.name==='core.ready').body.data.pid;
    let alive=true;
    for(let attempt=0;attempt<20;attempt++){
      try{process.kill(corePID,0);}catch(error){if(error.code==='ESRCH'){alive=false;break;}throw error;}
      await delay(100);
    }
    assert.equal(alive,false);
    const original=fs.readFileSync(path.join(root,'SharedSpec/Swift/PetCore/PetLogic.swift'));
    fs.writeFileSync(path.join(verification,'business-step3.json'),JSON.stringify({platform:process.platform,realElectron:true,requestResponses:'passed',activeEvents:'passed',sequence:events.map(event=>event.body.seq),events,nativeWindow:window,coreExited:true,sourceRulesSHA256:createHash('sha256').update(original).digest('hex'),animations:fs.readdirSync(path.join(root,'../DemoTheme')).filter(name=>name.endsWith('.png')).length},null,2));
    console.log('PASS: real Electron received active state/animation events; native pet and host exited cleanly');
  }catch(error){console.error('Business smoke validation failed:',error.message);process.exitCode=1;}
});
