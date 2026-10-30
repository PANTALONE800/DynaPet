'use strict';
const fs = require('node:fs');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const root = path.resolve(__dirname, '..');
const build = path.join(root, '.build', 'debug'); fs.mkdirSync(build, {recursive:true});
const swiftFlags = ['-swift-version','5','-module-cache-path',path.join(root,'.build','module-cache')];
const duplicate = '/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap';
let overlay;
if (process.platform === 'darwin' && fs.existsSync(duplicate) && fs.existsSync(path.join(path.dirname(duplicate),'bridging.modulemap'))) {
  const empty = path.join(root,'.build','empty.modulemap'); fs.writeFileSync(empty,'// Local build overlay only.\n');
  overlay = path.join(root,'.build','overlay.json'); fs.writeFileSync(overlay, JSON.stringify({version:0,roots:[{type:'file',name:duplicate,'external-contents':empty}]}));
  swiftFlags.push('-vfsoverlay',overlay);
}
function run(command,args) {
  const result = spawnSync(command,args,{cwd:root,stdio:'inherit'});
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
// Direct compilation also works around an inconsistent PackageDescription
// binary/interface in this host's Command Line Tools; Package.swift is retained
// for machines with a working Swift Package Manager installation.
const mac = process.platform === 'darwin';
if (!mac) throw Error('MacPlatform builds only on macOS; SharedSpec is the portable specification');
const library = 'libIPCProtocol.dylib';
const libraryIdentity = mac ? ['-Xlinker','-install_name','-Xlinker','@rpath/'+library] : [];
const domain = path.join(root,'SharedSpec','Swift','PetCore');
const domainLibrary = 'libPetCore.dylib';
const domainIdentity = mac ? ['-Xlinker','-install_name','-Xlinker','@rpath/'+domainLibrary] : [];
const domainSources = fs.readdirSync(domain).filter(file=>file.endsWith('.swift')).map(file=>path.join(domain,file));
run('swiftc',[...swiftFlags,'-emit-library','-emit-module','-module-name','PetCore',...domainSources,'-emit-module-path',path.join(build,'PetCore.swiftmodule'),...domainIdentity,'-o',path.join(build,domainLibrary)]);
const sources = fs.readdirSync(path.join(root,'SharedSpec/Swift/Core')).filter(file => file.endsWith('.swift')).map(file => path.join('SharedSpec/Swift/Core',file));
run('clang',['-std=c11','-D_POSIX_C_SOURCE=200809L','-pthread','-Wall','-Wextra','-Werror','-I','MacPlatform/Bridge/CSystem/include','-c','MacPlatform/Bridge/CSystem/lifecycle.c','-o',path.join(build,'lifecycle.o')]);
run('swiftc',[...swiftFlags,'-I',build,'-L',build,'-lPetCore','-emit-library','-emit-module','-enable-testing',...libraryIdentity,'-module-name','IPCProtocol',...sources,'-emit-module-path',path.join(build,'IPCProtocol.swiftmodule'),'-o',path.join(build,library)]);
run('swiftc',[...swiftFlags,'-I','MacPlatform/Bridge/CSystem/include','-I',build,'-L',build,'-lIPCProtocol','-lPetCore','-emit-library','-emit-module','-module-name','MacIPCTransport','MacPlatform/Transport/StreamIO.swift',path.join(build,'lifecycle.o'),'-emit-module-path',path.join(build,'MacIPCTransport.swiftmodule'),'-Xlinker','-install_name','-Xlinker','@rpath/libMacIPCTransport.dylib','-Xlinker','-rpath','-Xlinker','@loader_path','-o',path.join(build,'libMacIPCTransport.dylib')]);
const linking = ['-I','MacPlatform/Bridge/CSystem/include','-I',build,'-L',build,'-lIPCProtocol','-lPetCore','-lMacIPCTransport','-Xlinker','-rpath','-Xlinker',mac?'@executable_path':'$ORIGIN'];
run('swiftc',[...swiftFlags,...linking,'-I','MacPlatform/Bridge/CSystem/include','MacPlatform/Runtime/IPCProbe/main.swift','-o',path.join(build,'ipc-core-demo')]);
run('swiftc',[...swiftFlags,...linking,'SharedSpec/Tests/Swift/FramingTests.swift','SharedSpec/Tests/Swift/RouterChecks.swift','SharedSpec/Tests/Swift/BusinessChecks.swift','SharedSpec/Tests/Swift/main.swift','-o',path.join(build,'transport-tests')]);
run(path.join(build,'transport-tests'),[]);
run(process.execPath,['--test','tests/stream.test.cjs']);
run(process.execPath,['MacPlatform/Tools/IPCProbe/demo.cjs']);
