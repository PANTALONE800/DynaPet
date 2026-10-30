'use strict';
const path = require('node:path');
const {CoreProcess} = require('./core-process.cjs');

function resolveCoreExecutable(app, {resourcesPath = process.resourcesPath} = {}) {
  if (app.isPackaged) {
    if (!resourcesPath || !path.isAbsolute(resourcesPath)) throw Error('INVALID_RESOURCES_PATH');
    // extraResources is outside app.asar; never resolve a binary inside asar.
    return path.join(resourcesPath, 'DynaPet.app', 'Contents', 'MacOS', 'DynaPet');
  }
  return path.resolve(__dirname, '../../..', 'dist', process.arch, 'DynaPet.app', 'Contents', 'MacOS', 'DynaPet');
}
function createBundledCore(app, options = {}) {
  return new CoreProcess(resolveCoreExecutable(app), {...options, args: ['--ipc', ...(options.args || [])]});
}
module.exports = {resolveCoreExecutable, createBundledCore};
