import Foundation
import IPCProtocol

/// Native composition entry point. All actual behavior is owned by the shared
/// PetController, whose only window dependency is PetWindowHandling.
public final class MacPetManager: PetRequestHandling {
    public let controller: PetController
    public init(window: any PetWindowHandling, events: any PetEventPublishing) {
        controller = PetController(window: window, events: events)
    }
    public func touch(completion: @escaping (Result<Void, RequestFailure>) -> Void) { controller.touch(completion: completion) }
    public func resize(scale: Double, completion: @escaping (Result<Void, RequestFailure>) -> Void) { controller.resize(scale: scale, completion: completion) }
}
