import Foundation
import CoreFoundation
import Dispatch
import IPCProtocol
import MacIPCTransport
import CSystem

// This is a transport demo, not the pet's business core.
let logLock = NSLock()
func log(_ code: String) {
    logLock.lock(); defer { logLock.unlock() }
    try? FileHandle.standardError.write(contentsOf: Data(("ipc-core: " + code + "\n").utf8))
}
let writer = LineWriter(handle: .standardOutput)
// Keep the main run loop available for the next step's native UI adapter.
// Blocking stdin reads remain on LineReader's dedicated background queue.
let mainLoop = CFRunLoopGetMain()
var keepAliveContext = CFRunLoopSourceContext()
let keepAlive = CFRunLoopSourceCreate(nil, 0, &keepAliveContext)!
CFRunLoopAddSource(mainLoop, keepAlive, .defaultMode)
let stateQueue = DispatchQueue(label: "ipc.demo.dispatch")
var stopping = false
let events = EventEmitter(send: writer.send, onFault: log)
func event(_ name: String, data: [String: JSONValue] = [:]) { events.publish(name: name, data: data) }
func stop(_ reason: String) {
    guard !stopping else { return }
    stopping = true
    log("STOP_" + reason)
    event("core.stopping", data: ["reason": .string(reason)])
    DispatchQueue.main.async { CFRunLoopStop(mainLoop) }
}
writer.onFault = { code in log(code); stateQueue.async { stop("OUTPUT_FAILED") } }
guard ipc_prepare_signals() == 0 else { fatalError("Cannot prepare lifecycle signals") }
let signalSource = DispatchSource.makeSignalSource(signal: ipc_termination_signal(), queue: stateQueue)
signalSource.setEventHandler { stop("SIGTERM") }
signalSource.resume()
let expectedParent = ProcessInfo.processInfo.environment["DYNAPET_IPC_PARENT_PID"].flatMap(Int64.init) ?? ipc_parent_pid()
if ipc_watch_parent(expectedParent) != 0 { stateQueue.async { stop("PARENT_WATCH_FAILED") } }
// Test business module only; native pet/window integration is a later step.
final class DemoPet: PetRequestHandling {
    private var touches = 0
    private var scale = 1.0
    func touch(completion: @escaping (Result<Void, RequestFailure>) -> Void) {
        precondition(!Thread.isMainThread)
        touches += 1
        log("PET_TOUCH_DISPATCHED")
        completion(.success(()))
    }
    func resize(scale: Double, completion: @escaping (Result<Void, RequestFailure>) -> Void) {
        precondition(!Thread.isMainThread)
        self.scale = scale
        log("PET_RESIZE_DISPATCHED")
        completion(.success(()))
    }
}
let router = RequestRouter(pet: DemoPet())
let reader = LineReader(handle: .standardInput)
let inputSlots = DispatchSemaphore(value: 128)
stateQueue.sync { if !stopping { event("core.ready", data: ["pid": .number(Double(ipc_current_pid()))]) } }
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
CFRunLoopRun()
CFRunLoopRemoveSource(mainLoop, keepAlive, .defaultMode)
events.flush()
writer.flush()
signalSource.cancel()
