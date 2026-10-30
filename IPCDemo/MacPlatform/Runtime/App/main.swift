import Foundation
import AppKit
import MacPetWindowing
import CoreFoundation
import Dispatch
import IPCProtocol
import MacIPCTransport
import CSystem
import PetBridge
import Darwin

// GUI bundle defaults to native standalone mode; --ipc is an optional host mode.
if CommandLine.arguments.contains("--bridge-self-test") {
    do { try runPackagedBridgeSelfTest(); exit(0) }
    catch { fputs("PACKAGED_BRIDGE_SELF_TEST_FAILED\n", stderr); exit(1) }
}
let ipcMode = CommandLine.arguments.contains("--ipc") || ProcessInfo.processInfo.environment["DYNAPET_IPC_PARENT_PID"] != nil
let bridgeLinked = bridge_debug_live_handles() == 0
let logLock = NSLock()
func log(_ code: String) {
    logLock.lock(); defer { logLock.unlock() }
    try? FileHandle.standardError.write(contentsOf: Data(("ipc-core: " + code + "\n").utf8))
}
let writer = LineWriter(handle: .standardOutput)
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let defaultAssets = Bundle.main.resourceURL!.appendingPathComponent("DemoTheme")
let assets = ProcessInfo.processInfo.environment["DYNAPET_MAC_ASSETS"].map { URL(fileURLWithPath: $0) } ?? defaultAssets
let adapter = MacPetWindowAdapter(assets: assets)
let reportPath = ProcessInfo.processInfo.environment["DYNAPET_MAC_REPORT"]
let stateQueue = DispatchQueue(label: "ipc.demo.dispatch")
var stopping = false
let events = EventEmitter(send: { message in ipcMode ? writer.send(message) : true }, onFault: log)
let manager = MacPetManager(window: adapter, events: events)
let environment = MacPetEnvironment()
var nativeMenu: StandaloneMenu?
func event(_ name: String, data: [String: JSONValue] = [:]) { events.publish(name: name, data: data) }
func stop(_ reason: String) {
    guard !stopping else { return }
    stopping = true
    log("STOP_" + reason)
    environment.stop()
    manager.controller.stop {
        event("core.stopping", data: ["reason": .string(reason)])
        adapter.inspect { snapshot in
            if let reportPath, let encoded = try? JSONEncoder().encode(snapshot),
               var report = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] {
                report["ipcEnabled"] = ipcMode
                report["bridgeLinked"] = bridgeLinked
                report["bundlePath"] = Bundle.main.bundlePath
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
                }
            }
            adapter.closeWindow { _ in
                nativeMenu?.close(); nativeMenu = nil
                if !ipcMode {
                    NSApplication.shared.terminate(nil)
                    return
                }
                NSApp.stop(nil)
                if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                    NSApp.postEvent(wake, atStart: true)
                }
            }
        }
    }
}
writer.onFault = { code in log(code); stateQueue.async { stop("OUTPUT_FAILED") } }
guard ipc_prepare_signals() == 0 else { fatalError("Cannot prepare lifecycle signals") }
let signalSource = DispatchSource.makeSignalSource(signal: ipc_termination_signal(), queue: stateQueue)
signalSource.setEventHandler { stop("SIGTERM") }
signalSource.resume()
let expectedParent = ProcessInfo.processInfo.environment["DYNAPET_IPC_PARENT_PID"].flatMap(Int64.init) ?? ipc_parent_pid()
if ipcMode && ipc_watch_parent(expectedParent) != 0 { stateQueue.async { stop("PARENT_WATCH_FAILED") } }
let router = RequestRouter(pet: manager)
let reader = LineReader(handle: .standardInput)
let inputSlots = DispatchSemaphore(value: 128)
if !ipcMode {
    nativeMenu = StandaloneMenu(pet: manager, window: adapter) { stateQueue.async { stop("USER_QUIT") } }
}
adapter.showWindow { result in
    switch result {
    case .success:
        manager.controller.start { result in
            switch result {
            case .failure: stateQueue.async { stop("PET_STARTUP_FAILED") }
            case .success:
                adapter.inspect { snapshot in
                    stateQueue.async {
                        guard !stopping else { return }
                        environment.start(onSnapshot: { manager.controller.receive($0, screenTimeout: $1) },
                                          onSleep: { manager.controller.sleep() }, onWake: { manager.controller.wake() })
                        event("core.ready", data: ["pid": .number(Double(ipc_current_pid())), "nativeWindowVisible": .bool(snapshot.visible)])
                    }
                }
            }
        }
    case .failure: stateQueue.async { log("WINDOW_STARTUP_FAILED"); stop("WINDOW_STARTUP_FAILED") }
    }
}
if ipcMode {
reader.start(onMessage: { message in
    // This wait applies pipe backpressure only to the background reader.
    inputSlots.wait()
    stateQueue.async {
        guard !stopping else { inputSlots.signal(); return }
        guard message.type == .request else {
            log("UNEXPECTED_MESSAGE_TYPE"); inputSlots.signal(); return
        }
        router.route(message) { reply in
            stateQueue.async {
                defer { inputSlots.signal() }
                guard !stopping else { return }
                writer.send(reply.response)
                if reply.shutdownRequested { stop("SHUTDOWN_REQUEST") }
            }
        }
    }
}, onFault: { log($0) }, onEOF: { ipc_request_termination() })
}
application.run()
events.flush()
writer.flush()
signalSource.cancel()
