'use strict';
const path = require('node:path');
const project = path.resolve(__dirname, '../../..');
// Optional integration example for an existing Electron host. The native Mac
// product built by the root Makefile does not require Electron.
module.exports = {
  appId: 'local.dynapet.optionalhost',
  productName: 'DynaPetHost',
  asar: true,
  extraResources: [{
    from: path.join(project, 'dist', '${arch}', 'DynaPet.app'),
    to: 'DynaPet.app',
    filter: ['**/*']
  }],
  mac: {target: ['zip'], identity: '-', hardenedRuntime: false}
};
