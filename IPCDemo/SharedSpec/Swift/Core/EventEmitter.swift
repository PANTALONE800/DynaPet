import Foundation
import Dispatch

public protocol PetEventPublishing: AnyObject {
    func publish(name: String, data: [String: JSONValue])
}

/// One emitter per process: lifecycle and business events share one sequence.
/// No caller performs a pipe write or waits for the receiver on its own queue.
public final class EventEmitter: PetEventPublishing {
    private let queue = DispatchQueue(label: "ipc.events")
    private let send: (Message) -> Bool
    private let onFault: (String) -> Void
    private let session = String(UUID().uuidString.prefix(8))
    private var sequence = 0
    public init(send: @escaping (Message) -> Bool, onFault: @escaping (String) -> Void = { _ in }) {
        self.send = send; self.onFault = onFault
    }
    public func publish(name: String, data: [String: JSONValue] = [:]) {
        queue.async { [self] in
            guard sequence < 9_007_199_254_740_991 else { onFault("EVENT_SEQUENCE_EXHAUSTED"); return }
            let next = sequence + 1
            let message = Message(id: "e-\(session)-\(next)", type: .event,
                                  body: ["name": .string(name), "seq": .number(Double(next)), "data": .object(data)])
            do { _ = try message.encodedLine() }
            catch { onFault("INVALID_EVENT"); return }
            sequence = next
            if !send(message) { onFault("EVENT_OUTPUT_FAILED") }
        }
    }
    public func flush(timeout: DispatchTimeInterval = .milliseconds(300)) {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }
}
