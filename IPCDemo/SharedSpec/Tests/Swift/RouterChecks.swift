import Foundation
import Dispatch
import IPCProtocol

private final class MockPet: PetRequestHandling {
    enum Behavior { case immediate, mainQueue, twice, never, hold, failure }
    let behavior: Behavior
    private let lock = NSLock()
    private var touchCalls = 0
    private var sizes: [Double] = []
    private var onMain = false
    private var held: ((Result<Void, RequestFailure>) -> Void)?
    init(_ behavior: Behavior = .immediate) { self.behavior = behavior }
    var count: Int { lock.lock(); defer { lock.unlock() }; return touchCalls }
    var resizeValues: [Double] { lock.lock(); defer { lock.unlock() }; return sizes }
    var calledOnMain: Bool { lock.lock(); defer { lock.unlock() }; return onMain }
    func touch(completion: @escaping (Result<Void, RequestFailure>) -> Void) {
        lock.lock(); touchCalls += 1; onMain = Thread.isMainThread
        if behavior == .hold { held = completion }
        lock.unlock()
        switch behavior {
        case .immediate: completion(.success(()))
        case .mainQueue: DispatchQueue.main.async { precondition(Thread.isMainThread); completion(.success(())) }
        case .twice:
            DispatchQueue.global().async { completion(.success(())) }
            DispatchQueue.global().async { completion(.success(())) }
        case .never, .hold: break
        case .failure: completion(.failure(RequestFailure(code: "PRIVATE_DETAIL", message: "private backend data")))
        }
    }
    func release() {
        lock.lock(); let callback = held; held = nil; lock.unlock()
        callback?(.success(()))
    }
    func resize(scale: Double, completion: @escaping (Result<Void, RequestFailure>) -> Void) {
        lock.lock(); sizes.append(scale); onMain = Thread.isMainThread; lock.unlock()
        completion(.success(()))
    }
}
private final class Replies {
    private let lock = NSLock()
    private var values: [RoutedReply] = []
    func append(_ value: RoutedReply) { lock.lock(); values.append(value); lock.unlock() }
    var snapshot: [RoutedReply] { lock.lock(); defer { lock.unlock() }; return values }
}
private func pump(until ready: () -> Bool, timeout: TimeInterval = 1) {
    let deadline = Date().addingTimeInterval(timeout)
    while !ready() && Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    precondition(ready(), "Router response timeout")
}
private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> Message {
    Message(id: UUID().uuidString, type: .request, body: ["method": .string(method), "params": .object(params)])
}
private func response(_ router: RequestRouter, _ message: Message) -> RoutedReply {
    let replies = Replies(); router.route(message) { replies.append($0) }
    pump(until: { !replies.snapshot.isEmpty }); return replies.snapshot[0]
}
private func errorCode(_ reply: RoutedReply) -> String? { reply.response.body["error"]?.object?["code"]?.string }

final class RouterChecks {
    func testTouchRoutesToBusinessModuleOffMain() {
        let pet = MockPet(), message = request("pet.touch")
        let reply = response(RequestRouter(pet: pet), message)
        precondition(pet.count == 1 && !pet.calledOnMain)
        precondition(reply.response.id == message.id && reply.response.body["ok"] == .bool(true))
    }
    func testWhitelistAndParameterFailuresHaveNoSideEffects() {
        let pet = MockPet(), router = RequestRouter(pet: pet)
        precondition(errorCode(response(router, request("pet.delete"))) == "METHOD_NOT_FOUND")
        for params: [String: JSONValue] in [[:], ["scale": .bool(true)], ["scale": .number(10)], ["scale": .number(.nan)], ["scale": .number(1), "extra": .bool(true)]] {
            precondition(errorCode(response(router, request("pet.resize", params))) == "INVALID_PARAMS")
        }
        precondition(errorCode(response(router, request("pet.touch", ["extra": .bool(true)]))) == "INVALID_PARAMS")
        precondition(pet.count == 0 && pet.resizeValues.isEmpty)
    }
    func testOnlySupportedScalesReachBusinessModule() {
        let pet = MockPet(), router = RequestRouter(pet: pet)
        for scale in [0.75, 1.0, 1.25] {
            precondition(response(router, request("pet.resize", ["scale": .number(scale)])).response.body["ok"] == .bool(true))
        }
        precondition(pet.resizeValues == [0.75, 1.0, 1.25] && !pet.calledOnMain)
    }
    func testMainQueueCompletionDoesNotDeadlock() {
        let router = RequestRouter(pet: MockPet(.mainQueue))
        precondition(response(router, request("pet.touch")).response.body["ok"] == .bool(true))
    }
    func testDuplicateModuleCompletionProducesOneResponse() {
        let router = RequestRouter(pet: MockPet(.twice)), replies = Replies()
        router.route(request("pet.touch")) { replies.append($0) }
        pump(until: { !replies.snapshot.isEmpty })
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        precondition(replies.snapshot.count == 1)
    }
    func testMissingModuleCompletionTimesOut() {
        let router = RequestRouter(pet: MockPet(.never), operationTimeout: .milliseconds(40))
        precondition(errorCode(response(router, request("pet.touch"))) == "OPERATION_TIMEOUT")
    }
    func testLateCompletionDoesNotSendSecondResponse() {
        let pet = MockPet(.hold), router = RequestRouter(pet: pet, operationTimeout: .milliseconds(40)), replies = Replies()
        router.route(request("pet.touch")) { replies.append($0) }
        pump(until: { !replies.snapshot.isEmpty })
        precondition(errorCode(replies.snapshot[0]) == "OPERATION_TIMEOUT")
        pet.release()
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        precondition(replies.snapshot.count == 1)
    }
    func testAsynchronousOperationDoesNotBlockControlRequests() {
        let pet = MockPet(.hold), router = RequestRouter(pet: pet), touches = Replies()
        router.route(request("pet.touch")) { touches.append($0) }
        let pong = response(router, request("ping"))
        precondition(pong.response.body["result"]?.object?["pong"] == .bool(true))
        precondition(touches.snapshot.isEmpty)
        pet.release(); pump(until: { touches.snapshot.count == 1 })
    }
    func testModuleFailureDoesNotLeakInternalDetails() {
        let reply = response(RequestRouter(pet: MockPet(.failure)), request("pet.touch"))
        precondition(errorCode(reply) == "OPERATION_FAILED")
        precondition(reply.response.body["error"]?.object?["message"] == .string("Operation failed"))
    }
}
