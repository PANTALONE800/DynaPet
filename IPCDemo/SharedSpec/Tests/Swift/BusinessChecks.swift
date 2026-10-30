import Foundation
import Dispatch
import IPCProtocol
import PetCore

private final class Clock {
    private let lock = NSLock(); private var value = Date(timeIntervalSince1970: 1000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock() }
}
private final class EventRecorder: PetEventPublishing {
    private let lock = NSLock(); private var values: [(String, [String: JSONValue])] = []
    func publish(name: String, data: [String: JSONValue]) { lock.lock(); values.append((name, data)); lock.unlock() }
    var records: [(String, [String: JSONValue])] { lock.lock(); defer { lock.unlock() }; return values }
}
private final class BusinessWindow: PetWindowHandling {
    private let lock = NSLock()
    private var names: [String] = [], text = "", size = 1.0
    var failAnimation = false, failResize = false
    var animations: [String] { lock.lock(); defer { lock.unlock() }; return names }
    var scale: Double { lock.lock(); defer { lock.unlock() }; return size }
    var caption: String { lock.lock(); defer { lock.unlock() }; return text }
    func showWindow(completion: @escaping PetWindowCompletion) { completion(.success(())) }
    func setAlwaysOnTop(_ isOn: Bool, completion: @escaping PetWindowCompletion) { completion(.success(())) }
    func setClickThrough(_ isOn: Bool, completion: @escaping PetWindowCompletion) { completion(.success(())) }
    func updatePosition(x: Double, y: Double, completion: @escaping PetWindowCompletion) { completion(.success(())) }
    func updateSize(scale: Double, completion: @escaping PetWindowCompletion) {
        if failResize { completion(.failure(.windowUnavailable)); return }
        lock.lock(); size = scale; lock.unlock(); completion(.success(()))
    }
    func playAnimation(name: String, completion: @escaping PetWindowCompletion) {
        if failAnimation { completion(.failure(.assetUnavailable)); return }
        lock.lock(); names.append(name); lock.unlock(); completion(.success(()))
    }
    func updateStatusText(_ text: String, completion: @escaping PetWindowCompletion) {
        lock.lock(); self.text = text; lock.unlock(); completion(.success(()))
    }
    func closeWindow(completion: @escaping PetWindowCompletion) { completion(.success(())) }
}
private final class Box<T> {
    private let lock = NSLock(); private var stored: T?
    var value: T? { get { lock.lock(); defer { lock.unlock() }; return stored } set { lock.lock(); stored = newValue; lock.unlock() } }
}
private func wait(_ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(2)
    while !predicate() && Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    precondition(predicate(), "Business check timed out")
}
private func complete(_ operation: (@escaping (Result<Void, RequestFailure>) -> Void) -> Void, succeeds: Bool = true) {
    let result = Box<Result<Void, RequestFailure>>()
    operation { result.value = $0 }; wait { result.value != nil }
    switch result.value! { case .success: precondition(succeeds); case .failure: precondition(!succeeds) }
}
private func current(_ controller: PetController) -> PetBusinessState {
    let result = Box<PetBusinessState>(); controller.inspect { result.value = $0 }; wait { result.value != nil }; return result.value!
}
private func setup() -> (PetController, BusinessWindow, EventRecorder, Clock) {
    let window = BusinessWindow(), events = EventRecorder(), clock = Clock()
    let controller = PetController(window: window, events: events, now: clock.now)
    complete(controller.start)
    return (controller, window, events, clock)
}
final class BusinessChecks {
    func testStartupActivelyPublishesWelcomeWithoutAnyRequest() {
        let (controller, window, events, _) = setup()
        precondition(current(controller).mood == .welcome && window.animations == ["welcome"])
        precondition(events.records.map { $0.0 } == ["pet.state_changed", "play_animation"])
        precondition(events.records[0].1["reason"] == .string("startup"))
    }
    func testTouchCommitsActualWindowAndThenPublishesHappy() {
        let (controller, window, events, _) = setup()
        complete(controller.touch)
        precondition(current(controller).mood == .happy && window.animations.last == "happy")
        precondition(window.caption == "嘿嘿，被你摸摸啦～")
        precondition(events.records.last?.0 == "play_animation" && events.records.last?.1["name"] == .string("happy"))
    }
    func testRealLowBatteryAndCpuRulesAreReused() {
        let (controller, _, _, clock) = setup()
        clock.advance(15)
        var battery = Snapshot(); battery.battery = 10; battery.charging = false
        controller.receive(battery); wait { current(controller).mood == .low }
        clock.advance(10)
        var cpu = Snapshot(); cpu.cpu = 90; cpu.battery = 80
        controller.receive(cpu); wait { current(controller).mood == .dizzy }
    }
    func testRealWorkAndIdleRulesAreReused() {
        let (controller, _, _, clock) = setup(); clock.advance(15)
        var work = Snapshot(); work.front = "Visual Studio Code"
        controller.receive(work); wait { current(controller).mood == .focus }
        clock.advance(10)
        var idle = Snapshot(); idle.idle = 280
        controller.receive(idle, screenTimeout: 300); wait { current(controller).mood == .sleepy }
    }
    func testTouchHoldPreventsAutomaticMoodFlicker() {
        let (controller, _, _, clock) = setup(); clock.advance(20); complete(controller.touch)
        var busy = Snapshot(); busy.cpu = 95
        controller.receive(busy)
        // An ordered resize completion also drains the preceding sample job.
        complete { controller.resize(scale: 1, completion: $0) }
        precondition(current(controller).mood == .happy)
        clock.advance(10); controller.receive(busy); wait { current(controller).mood == .dizzy }
    }
    func testUnchangedAutomaticMoodDoesNotRestartAnimation() {
        let (controller, window, _, clock) = setup(); clock.advance(15)
        var value = Snapshot(); value.front = "Finder"
        controller.receive(value); wait { current(controller).mood == .puzzled }
        let count = window.animations.count
        controller.receive(value); complete { controller.resize(scale: 1, completion: $0) }
        precondition(window.animations.count == count)
    }
    func testResizePublishesAppliedScaleAndState() {
        let (controller, window, events, _) = setup()
        complete { controller.resize(scale: 1.25, completion: $0) }
        precondition(window.scale == 1.25 && current(controller).scale == 1.25)
        precondition(events.records.contains { $0.0 == "pet.resized" && $0.1["scale"] == .number(1.25) })
    }
    func testFailedAnimationDoesNotCommitStateOrPublishSuccess() {
        let (controller, window, events, _) = setup(); let count = events.records.count
        window.failAnimation = true; complete(controller.touch, succeeds: false)
        precondition(current(controller).mood == .welcome && events.records.count == count)
    }
    func testFailedResizeDoesNotCommitScale() {
        let (controller, window, events, _) = setup(); let count = events.records.count
        window.failResize = true; complete({ controller.resize(scale: 1.25, completion: $0) }, succeeds: false)
        precondition(current(controller).scale == 1 && events.records.count == count)
    }
    func testSleepWakeAndStopDoNotLeakLateStateEvents() {
        let (controller, _, events, clock) = setup()
        controller.sleep(); wait { current(controller).mood == .sleepy }
        clock.advance(100); controller.receive(Snapshot()); complete { controller.resize(scale: 1, completion: $0) }
        precondition(current(controller).mood == .sleepy)
        controller.wake(); wait { current(controller).mood == .welcome }
        let stopped = Box<Bool>(); controller.stop { stopped.value = true }; wait { stopped.value == true }
        let count = events.records.count
        controller.receive(Snapshot()); complete(controller.touch, succeeds: false)
        precondition(events.records.count == count)
    }
    func testAllOriginalAnimationsReachTheirThreeFrames() {
        precondition(Mood.allCases.count == 11)
        for mood in Mood.allCases {
            let duration = mood.animationTiming.period
            let indices = Set((0...1200).map { mood.animationFrame(at: Double($0) / 1200 * duration) })
            precondition(indices == [0, 1, 2])
        }
    }
    func testConcurrentEventsHaveOneStrictlyIncreasingSequence() {
        let records = Box<[Message]>(); records.value = []
        let lock = NSLock()
        let emitter = EventEmitter(send: { message in lock.lock(); records.value = (records.value ?? []) + [message]; lock.unlock(); return true })
        let producers = DispatchGroup()
        for index in 0..<100 {
            producers.enter(); DispatchQueue.global().async { emitter.publish(name: "test.changed", data: ["index": .number(Double(index))]); producers.leave() }
        }
        producers.wait(); emitter.flush()
        let messages = records.value!
        precondition(messages.count == 100)
        precondition(messages.enumerated().allSatisfy { $0.element.body["seq"] == .number(Double($0.offset + 1)) })
        precondition(Set(messages.map(\.id)).count == 100)
    }
    func testInvalidEventIsDroppedWithoutPoisoningNextSequence() {
        let records = Box<[Message]>(); records.value = []
        let faults = Box<[String]>(); faults.value = []
        let emitter = EventEmitter(send: { message in records.value = (records.value ?? []) + [message]; return true }, onFault: { code in faults.value = (faults.value ?? []) + [code] })
        emitter.publish(name: "invalid event", data: [:]); emitter.publish(name: "valid.event", data: [:]); emitter.flush()
        precondition(faults.value == ["INVALID_EVENT"] && records.value?.count == 1)
        precondition(records.value?.first?.body["seq"] == .number(1))
    }
}
