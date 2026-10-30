'use strict';
const fs = require('node:fs');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
if (process.platform !== 'darwin') throw Error('AppKit demo requires macOS');
const root = path.resolve(__dirname, '..'), build = path.join(root,'.build','debug');
const modulePath = path.join(build,'IPCProtocol.swiftmodule');
if (!fs.existsSync(modulePath) || fs.readdirSync(path.join(root,'SharedSpec/Swift/Core')).some(file => file.endsWith('.swift') && fs.statSync(path.join(root,'SharedSpec/Swift/Core',file)).mtimeMs > fs.statSync(modulePath).mtimeMs)) throw Error('First run: node IPCDemo/scripts/build-and-test.cjs');
const flags = ['-O','-swift-version','5','-module-cache-path',path.join(root,'.build','module-cache'),'-I',build,'-I','MacPlatform/Bridge/CSystem/include','-L',build,'-lIPCProtocol','-lPetCore','-lMacIPCTransport'];
const overlay = path.join(root,'.build','overlay.json'); if (fs.existsSync(overlay)) flags.push('-vfsoverlay',overlay);
function run(command,args) { const result=spawnSync(command,args,{cwd:root,stdio:'inherit'});if(result.error)throw result.error;if(result.status!==0)process.exit(result.status??1); }
run('swiftc',[...flags,'-emit-library','-emit-module','-module-name','MacPetWindowing','MacPlatform/AppKit/MacPetWindowAdapter.swift','MacPlatform/AppKit/MacPetManager.swift','MacPlatform/AppKit/MacPetEnvironment.swift','-emit-module-path',path.join(build,'MacPetWindowing.swiftmodule'),'-Xlinker','-install_name','-Xlinker','@rpath/libMacPetWindowing.dylib','-Xlinker','-rpath','-Xlinker','@loader_path','-o',path.join(build,'libMacPetWindowing.dylib'),'-framework','AppKit','-framework','ImageIO','-framework','IOKit','-framework','ApplicationServices']);
const app = path.join(root,'.build','mac','DynaPet IPC Mac Demo.app'), contents=path.join(app,'Contents'), macos=path.join(contents,'MacOS'), resources=path.join(contents,'Resources','DemoTheme');
fs.mkdirSync(macos,{recursive:true});fs.mkdirSync(resources,{recursive:true});
run('make',['-C','MacPlatform/Bridge/PetBridge','all']);
const bridgeLib=path.join(root,'.build','petbridge',process.arch,'Frameworks');
run('swiftc',[...flags,'-lMacPetWindowing','-I','MacPlatform/Bridge/PetBridge/include','-L',bridgeLib,'-lpetbridge','MacPlatform/Runtime/App/BridgeSelfTest.swift','MacPlatform/Runtime/App/StandaloneMenu.swift','MacPlatform/Runtime/App/main.swift','-Xlinker','-rpath','-Xlinker','@executable_path','-o',path.join(macos,'dynapet-mac-core'),'-framework','AppKit']);
fs.copyFileSync(path.join(bridgeLib,'libpetbridge.dylib'),path.join(macos,'libpetbridge.dylib'));
for(const library of ['libIPCProtocol.dylib','libMacPetWindowing.dylib','libPetCore.dylib','libMacIPCTransport.dylib'])fs.copyFileSync(path.join(build,library),path.join(macos,library));
for(const name of fs.readdirSync(path.join(root,'..','DemoTheme')).filter(file=>file.endsWith('.png')).map(file=>file.slice(0,-4)))fs.copyFileSync(path.join(root,'..','DemoTheme',name+'.png'),path.join(resources,name+'.png'));
fs.writeFileSync(path.join(contents,'Info.plist'),`<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.dynapet.ipc.macdemo</string><key>CFBundleName</key><string>DynaPet IPC Mac Demo</string><key>CFBundleExecutable</key><string>dynapet-mac-core</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/><key>NSHighResolutionCapable</key><true/><key>LSMinimumSystemVersion</key><string>14.0</string></dict></plist>`);
for(const library of ['libIPCProtocol.dylib','libMacPetWindowing.dylib','libPetCore.dylib','libMacIPCTransport.dylib','libpetbridge.dylib'])run('codesign',['--force','--sign','-',path.join(macos,library)]);
run('codesign',['--force','--sign','-',app]);
console.log('Built:',app);
if(fs.existsSync(path.join(root,'MacPlatform','Tests','MacWindowChecks','main.swift'))){
 run('swiftc',[...flags,'-lMacPetWindowing','MacPlatform/Tests/MacWindowChecks/main.swift','-Xlinker','-rpath','-Xlinker','@executable_path','-o',path.join(build,'mac-window-checks'),'-framework','AppKit','-framework','ApplicationServices']);
}

if(fs.existsSync(path.join(build,'mac-window-checks'))){
 const checksApp=path.join(root,'.build','mac','DynaPet Window Checks.app'), checksContents=path.join(checksApp,'Contents'), checksMac=path.join(checksContents,'MacOS');
 fs.mkdirSync(checksMac,{recursive:true});
 fs.copyFileSync(path.join(build,'mac-window-checks'),path.join(checksMac,'mac-window-checks'));
 for(const library of ['libIPCProtocol.dylib','libMacPetWindowing.dylib','libPetCore.dylib','libMacIPCTransport.dylib'])fs.copyFileSync(path.join(build,library),path.join(checksMac,library));
 fs.writeFileSync(path.join(checksContents,'Info.plist'),'<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.dynapet.ipc.windowchecks</string><key>CFBundleName</key><string>DynaPet Window Checks</string><key>CFBundleExecutable</key><string>mac-window-checks</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>');
 run('codesign',['--force','--sign','-',checksApp]);
}
