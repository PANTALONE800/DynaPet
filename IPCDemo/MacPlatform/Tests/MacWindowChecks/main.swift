import AppKit
import ApplicationServices
import MacPetWindowing
import IPCProtocol

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.finishLaunching()
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let assets = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let adapter = MacPetWindowAdapter(assets: assets)
var checks: [String] = []
func passed(_ name: String) { checks.append(name); print("PASS: " + name) }
func pump(_ duration: TimeInterval) {
    let end = Date().addingTimeInterval(duration)
    while Date() < end { _ = RunLoop.current.run(mode: .default, before: min(end, Date().addingTimeInterval(0.01))) }
}
func operation(_ invoke: @escaping (@escaping PetWindowCompletion) -> Void, shouldFail: Bool = false, requireMain: Bool = true) {
    let lock = NSLock(); var completed: Result<Void, PetWindowFailure>?
    DispatchQueue.global().async { invoke { result in
        if requireMain { precondition(Thread.isMainThread) }
        lock.lock(); completed = result; lock.unlock()
    } }
    let end = Date().addingTimeInterval(4)
    while true {
        lock.lock(); let result = completed; lock.unlock()
        if let result {
            switch result {
            case .success: precondition(!shouldFail)
            case .failure: precondition(shouldFail)
            }
            return
        }
        precondition(Date() < end, "AppKit operation did not complete")
        pump(0.01)
    }
}
func snapshot() -> MacWindowSnapshot {
    var result: MacWindowSnapshot?
    adapter.inspect { result = $0 }
    while result == nil { pump(0.01) }
    return result!
}
operation { adapter.showWindow(completion: $0) }
let initial = snapshot()
precondition(initial.visible && initial.borderless && initial.transparent && initial.windowNumber > 0)
passed("transparent borderless native window is visible")
precondition(initial.level == initial.floatingLevel)
passed("window starts at floating level")
operation { adapter.setAlwaysOnTop(false, completion: $0) }
precondition(snapshot().level == NSWindow.Level.normal.rawValue)
operation { adapter.setAlwaysOnTop(true, completion: $0) }
precondition(snapshot().level == initial.floatingLevel)
passed("always-on-top switches between normal and floating")
operation { adapter.setClickThrough(true, completion: $0) }
precondition(snapshot().clickThrough)
operation { adapter.setClickThrough(false, completion: $0) }
precondition(!snapshot().clickThrough)
passed("click-through property toggles on the real window")
operation { adapter.updatePosition(x: 120, y: 140, completion: $0) }
let positioned = snapshot()
precondition(abs(positioned.x - 120) <= 1 && abs(positioned.y - 140) <= 1)
passed("desktop top-left coordinates convert correctly")
operation { adapter.updateSize(scale: 1.25, completion: $0) }
precondition(snapshot().width == 300 && snapshot().height == 325)
passed("resize changes actual native frame")
operation({ adapter.updateSize(scale: .infinity, completion: $0) }, shouldFail: true)
precondition(snapshot().width == 300)
passed("invalid size is rejected without changing the window")
operation { adapter.savePreview(to: root.appendingPathComponent("native-idle.png"), completion: $0) }
let manager = MacPetManager(window: adapter, events: EventEmitter(send: { _ in true }))
operation({ done in
    manager.touch { result in done(result.mapError { _ in PetWindowFailure.windowUnavailable }) }
}, requireMain: false)
precondition(snapshot().animation == "happy" && snapshot().animationStarts == 1)
passed("real manager starts happy animation before completion")
let before = snapshot().frameChanges
pump(0.3)
precondition(snapshot().frameChanges > before)
passed("native animation advances across real image frames")
operation { adapter.savePreview(to: root.appendingPathComponent("native-happy.png"), completion: $0) }
operation({ adapter.playAnimation(name: "not-a-real-animation", completion: $0) }, shouldFail: true)
precondition(snapshot().animation == "happy")
passed("unknown animation is rejected without altering current state")

// The earlier blue hit-test fixture is retired. No underlying colored window
// is created in business validation; step 2 already recorded its evidence.
let clickEvidence = "property_verified_only_this_run; system_hit_test_passed_in_step2"
precondition(snapshot().appliedOnMainThread)
passed("all native mutations and completions execute on the main thread")
operation { adapter.closeWindow(completion: $0) }
precondition(!snapshot().visible)
passed("window and animation timer are closed cleanly")
let report: [String: Any] = ["passed": checks, "clickThroughHitTest": clickEvidence, "platform": "macOS", "adapter": "AppKit", "initialWindowNumber": initial.windowNumber]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("adapter-checks.json"), options: .atomic)
print("AppKit checks: \(checks.count) passed")
