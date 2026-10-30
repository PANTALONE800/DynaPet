import Foundation
import PetBridge

struct BridgeFailure: Error, CustomStringConvertible {
    let description: String
}
func testBridge() throws {
    precondition(Thread.isMainThread)
    guard let pointer = bridge_create_test_window() else {
        throw BridgeFailure(description: String(cString: bridge_last_error()))
    }
    defer { bridge_destroy_window(pointer) }
    guard bridge_set_topmost(pointer, 1) == 0 else {
        throw BridgeFailure(description: String(cString: bridge_last_error()))
    }
    guard bridge_debug_is_topmost(pointer) == 1 else {
        throw BridgeFailure(description: "Native window is not floating")
    }
    print("PASS: Swift called bridge_create_test_window → bridge_set_topmost(ptr, 1)")
    // Only the minimal native test window; no pet, sensors, IPC, or state machine.
    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.12))
}
let repetitions = CommandLine.arguments.contains("--stress") ? 20 : 1
for _ in 0..<repetitions { try autoreleasepool { try testBridge() } }
let deadline = Date().addingTimeInterval(1)
while bridge_debug_live_native_windows() != 0 && Date() < deadline {
    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
}
guard bridge_debug_live_handles() == 0, bridge_debug_live_native_windows() == 0 else {
    throw BridgeFailure(description: "Unreleased bridge handles or native windows")
}
print("PASS: bridge_destroy_window completed; live_handles=0 live_native_windows=0; iterations=\(repetitions)")
