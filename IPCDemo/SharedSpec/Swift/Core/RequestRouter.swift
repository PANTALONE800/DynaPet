import Foundation
import Dispatch

public struct RequestFailure: Error {
    public let code: String
    public let message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
}

/// Implementations own their state and may complete on any queue. A future
/// window adapter must perform native UI work on its UI queue internally.
public protocol PetRequestHandling: AnyObject {
    func touch(completion: @escaping (Result<Void, RequestFailure>) -> Void)
    func resize(scale: Double, completion: @escaping (Result<Void, RequestFailure>) -> Void)
}

public struct RoutedReply {
    public let response: Message
    public let shutdownRequested: Bool
}

/// Closed whitelist: no reflection, selectors, or arbitrary module names from IPC.
public final class RequestRouter {
    private enum Method: String, CaseIterable {
        case touch = "pet.touch", resize = "pet.resize"
        // Transport demo/control methods, kept distinct from business commands.
        case echo, ping, shutdown
    }
    public static var allowedMethods: Set<String> { Set(Method.allCases.map(\.rawValue)) }
    private let pet: any PetRequestHandling
    private let queue = DispatchQueue(label: "ipc.request.router", qos: .userInitiated)
    private let operationTimeout: DispatchTimeInterval
    public init(pet: any PetRequestHandling, operationTimeout: DispatchTimeInterval = .seconds(3)) {
        self.pet = pet; self.operationTimeout = operationTimeout
    }

    /// Always asynchronous, including validation failures. No pipe reads or UI
    /// calls execute on this queue; a slow asynchronous operation cannot block ping.
    public func route(_ request: Message, completion: @escaping (RoutedReply) -> Void) {
        queue.async { [self] in
            dispatchPrecondition(condition: .notOnQueue(.main))
            let reply = ReplyOnce(requestID: request.id, queue: queue, completion: completion)
            guard request.type == .request else {
                reply.fail("INVALID_REQUEST", "Expected a request"); return
            }
            do { try request.validate() }
            catch { reply.fail("INVALID_REQUEST", "Invalid request structure"); return }
            guard let name = request.body["method"]?.string,
                  let method = Method(rawValue: name) else {
                reply.fail("METHOD_NOT_FOUND", "Unknown method"); return
            }
            guard let params = request.body["params"]?.object else {
                reply.fail("INVALID_PARAMS", "Expected an object"); return
            }
            switch method {
            case .echo: reply.succeed(params)
            case .ping, .shutdown:
                guard params.isEmpty else { reply.fail("INVALID_PARAMS", "This method accepts no parameters"); return }
                reply.succeed(method == .ping ? ["pong": .bool(true)] : [:], shutdown: method == .shutdown)
            case .touch:
                guard params.isEmpty else { reply.fail("INVALID_PARAMS", "pet.touch accepts no parameters"); return }
                reply.armTimeout(after: operationTimeout)
                pet.touch { result in
                    reply.finishOperation(result, value: ["accepted": .bool(true)])
                }
            case .resize:
                guard Set(params.keys) == ["scale"], case .number(let scale) = params["scale"],
                      scale.isFinite, [0.75, 1.0, 1.25].contains(scale) else {
                    reply.fail("INVALID_PARAMS", "scale must be 0.75, 1.0 or 1.25"); return
                }
                reply.armTimeout(after: operationTimeout)
                pet.resize(scale: scale) { result in
                    reply.finishOperation(result, value: ["scale": .number(scale)])
                }
            }
        }
    }
}

/// Each request gets one response even if a module completes twice or after its
/// deadline. All completion and timeout bookkeeping stays on the router queue.
private final class ReplyOnce {
    private let requestID: String
    private let queue: DispatchQueue
    private let completion: (RoutedReply) -> Void
    private var completed = false
    private var timer: DispatchWorkItem?
    init(requestID: String, queue: DispatchQueue, completion: @escaping (RoutedReply) -> Void) {
        self.requestID = requestID; self.queue = queue; self.completion = completion
    }
    func armTimeout(after delay: DispatchTimeInterval) {
        let timer = DispatchWorkItem { [self] in fail("OPERATION_TIMEOUT", "Operation did not complete in time") }
        self.timer = timer
        queue.asyncAfter(deadline: .now() + delay, execute: timer)
    }
    func finishOperation(_ result: Result<Void, RequestFailure>, value: [String: JSONValue]) {
        queue.async { [self] in
            switch result {
            case .success: succeed(value)
            case .failure:
                // Module errors may contain sensitive details. Only a stable,
                // transport-owned error is sent across the process boundary.
                fail("OPERATION_FAILED", "Operation failed")
            }
        }
    }
    func succeed(_ value: [String: JSONValue], shutdown: Bool = false) {
        finish(body: ["ok": .bool(true), "result": .object(value)], shutdown: shutdown)
    }
    func fail(_ code: String, _ message: String) {
        finish(body: ["ok": .bool(false), "error": .object(["code": .string(code), "message": .string(message)])])
    }
    private func finish(body: [String: JSONValue], shutdown: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !completed else { return }
        completed = true; timer?.cancel(); timer = nil
        completion(RoutedReply(response: Message(id: requestID, type: .response, body: body), shutdownRequested: shutdown))
    }
}
