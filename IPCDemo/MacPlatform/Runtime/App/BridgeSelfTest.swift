import Foundation
import PetBridge

func runPackagedBridgeSelfTest() throws {
    try autoreleasepool {
        guard let pointer = bridge_create_test_window() else { throw NSError(domain: "PetBridge", code: 1) }
        defer { bridge_destroy_window(pointer) }
        guard bridge_set_topmost(pointer, 1) == 0, bridge_debug_is_topmost(pointer) == 1 else {
            throw NSError(domain: "PetBridge", code: 2)
        }
        print("PASS: bundled libpetbridge create -> topmost -> destroy")
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.12))
    }
    guard bridge_debug_live_handles() == 0, bridge_debug_live_native_windows() == 0 else {
        throw NSError(domain: "PetBridge", code: 3)
    }
    print("PASS: bundled bridge live_handles=0 live_native_windows=0")
}
