'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..'),shared=path.join(root,'SharedSpec');
function files(dir){return fs.readdirSync(dir,{withFileTypes:true}).flatMap(entry=>entry.isDirectory()?files(path.join(dir,entry.name)):[path.join(dir,entry.name)]);}
const forbidden=/^\s*import\s+(AppKit|SwiftUI|CSystem|MacIPCTransport|MacPetWindowing|Darwin|Glibc|CX11|WinSDK)\b/m;
for(const file of files(path.join(shared,'Swift'))){
 assert(!/\.(c|h)$/.test(file),'Native C source in SharedSpec: '+file);
 if(file.endsWith('.swift'))assert(!forbidden.test(fs.readFileSync(file,'utf8')),'Platform dependency in shared reference: '+file);
}
const c=fs.readFileSync(path.join(root,'MacPlatform/Bridge/CSystem/lifecycle.c'),'utf8');
assert(!/__linux__|_WIN32|prctl/.test(c),'Cross-platform branch remains in Mac C code');
for(const name of ['PetLogic.swift','Animation.swift'])assert.equal(fs.readFileSync(path.join(root,'../DynaPetNative/Sources/PetCore',name),'utf8'),fs.readFileSync(path.join(shared,'Swift/PetCore',name),'utf8'));
console.log('PASS: SharedSpec has no platform imports or C sources; Mac C has no Linux/Win32 branches; legacy core paths resolve to canonical sources');
