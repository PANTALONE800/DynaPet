import Foundation
import Dispatch
import PetCore

public struct PetBusinessState {
    public let mood: Mood
    public let text: String
    public let scale: Double
    public let revision: Int
}

/// Real pet behavior. `decide` and animation definitions are imported directly
/// from the existing PetCore sources; this module contains no native UI APIs.
public final class PetController: PetRequestHandling {
    private struct Job {
        let perform: (@escaping () -> Void) -> Void
        let cancel: () -> Void
    }
    private let queue = DispatchQueue(label: "pet.business", qos: .userInitiated)
    private let window: any PetWindowHandling
    private let events: any PetEventPublishing
    private let now: () -> Date
    private var running = true, busy = false, sampleQueued = false, sleeping = false
    private var jobs: [Job] = []
    private var mood: Mood = .idle
    private var text = "我在这里陪着你。"
    private var scale = 1.0, revision = 0
    private var greetingUntil: Date
    private var touchedUntil = Date.distantPast, lastChange = Date.distantPast
    private var latest = Snapshot()
    private var screenTimeout = 300.0
    public init(window: any PetWindowHandling, events: any PetEventPublishing, now: @escaping () -> Date = Date.init) {
        self.window = window; self.events = events; self.now = now
        greetingUntil = now().addingTimeInterval(14)
    }
    private func failure() -> RequestFailure { RequestFailure(code: "PET_UNAVAILABLE", message: "Pet is stopping or the window operation failed") }
    private func enqueue(_ job: Job) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard running else { job.cancel(); return }
        jobs.append(job); drain()
    }
    private func drain() {
        guard running, !busy, !jobs.isEmpty else { return }
        busy = true
        let job = jobs.removeFirst()
        job.perform { [weak self] in self?.queue.async { [weak self] in self?.busy = false; self?.drain() } }
    }
    public func start(completion: @escaping (Result<Void, RequestFailure>) -> Void) {
        queue.async { [self] in
            enqueue(Job(perform: { done in
                self.transition(mood: .welcome, text: "你回来啦！今天也一起加油～", reason: "startup") { result in completion(result); done() }
            }, cancel: { completion(.failure(self.failure())) }))
        }
    }
    public func touch(completion: @escaping (Result<Void, RequestFailure>) -> Void) {
        queue.async { [self] in
            enqueue(Job(perform: { done in
                self.transition(mood: .happy, text: "嘿嘿，被你摸摸啦～", reason: "touch") { result in
                    if case .success = result { self.touchedUntil = self.now().addingTimeInterval(7) }
                    completion(result); done()
                }
            }, cancel: { completion(.failure(self.failure())) }))
        }
    }
    public func resize(scale: Double, completion: @escaping (Result<Void, RequestFailure>) -> Void) {
        queue.async { [self] in
            guard scale.isFinite, [0.75, 1.0, 1.25].contains(scale) else {
                completion(.failure(RequestFailure(code: "INVALID_PARAMS", message: "Unsupported scale"))); return
            }
            enqueue(Job(perform: { done in
                self.window.updateSize(scale: scale) { result in self.queue.async {
                    guard self.running else { completion(.failure(self.failure())); done(); return }
                    switch result {
                    case .success:
                        self.scale = scale; self.revision += 1
                        self.events.publish(name: "pet.resized", data: ["scale": .number(scale), "revision": .number(Double(self.revision))])
                        self.publishState(reason: "resize"); completion(.success(()))
                    case .failure: completion(.failure(self.failure()))
                    }
                    done()
                } }
            }, cancel: { completion(.failure(self.failure())) }))
        }
    }
    /// Sensor updates coalesce while a UI operation is in flight. A 7-second
    /// touch hold and the original 9-second mood hysteresis prevent flicker.
    public func receive(_ snapshot: Snapshot, screenTimeout: Double = 300) {
        queue.async { [self] in
            guard running, !sleeping else { return }
            latest = snapshot; self.screenTimeout = screenTimeout
            guard !sampleQueued else { return }
            sampleQueued = true
            enqueue(Job(perform: { done in
                self.sampleQueued = false
                let time = self.now()
                guard time >= self.touchedUntil else { done(); return }
                let decision = decide(self.latest, screenTimeout: self.screenTimeout, greeting: time < self.greetingUntil)
                guard decision.mood == self.mood || time.timeIntervalSince(self.lastChange) > 9 || decision.mood == .low || decision.mood == .welcome else { done(); return }
                guard decision.mood != self.mood || decision.text != self.text else { done(); return }
                self.transition(mood: decision.mood, text: decision.text, reason: "environment") { _ in done() }
            }, cancel: { self.sampleQueued = false }))
        }
    }
    public func sleep() {
        queue.async { [self] in
            sleeping = true; touchedUntil = .distantPast
            enqueue(Job(perform: { done in self.transition(mood: .sleepy, text: "晚安，等你回来。", reason: "sleep") { _ in done() } }, cancel: {}))
        }
    }
    public func wake() {
        queue.async { [self] in
            sleeping = false; greetingUntil = now().addingTimeInterval(14); touchedUntil = .distantPast
            enqueue(Job(perform: { done in self.transition(mood: .welcome, text: "你回来啦！刚刚休息得好吗？", reason: "wake") { _ in done() } }, cancel: {}))
        }
    }
    private func transition(mood nextMood: Mood, text nextText: String, reason: String, completion: @escaping (Result<Void, RequestFailure>) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        let animationChanged = nextMood != mood || reason == "touch" || reason == "startup" || reason == "wake"
        let finish: (Result<Void, PetWindowFailure>) -> Void = { result in self.queue.async {
            guard self.running else { completion(.failure(self.failure())); return }
            switch result {
            case .failure: completion(.failure(self.failure()))
            case .success:
                if nextMood != self.mood { self.lastChange = self.now() }
                self.mood = nextMood; self.text = nextText; self.revision += 1
                self.publishState(reason: reason)
                if animationChanged { self.events.publish(name: "play_animation", data: ["name": .string(nextMood.rawValue), "reason": .string(reason), "revision": .number(Double(self.revision))]) }
                completion(.success(()))
            }
        } }
        if animationChanged {
            window.playAnimation(name: nextMood.rawValue) { result in
                switch result {
                case .success: self.window.updateStatusText(nextText, completion: finish)
                case .failure: finish(result)
                }
            }
        } else { window.updateStatusText(nextText, completion: finish) }
    }
    private func publishState(reason: String) {
        events.publish(name: "pet.state_changed", data: ["mood": .string(mood.rawValue), "text": .string(text), "scale": .number(scale), "reason": .string(reason), "revision": .number(Double(revision))])
    }
    public func inspect(completion: @escaping (PetBusinessState) -> Void) {
        queue.async { [self] in completion(PetBusinessState(mood: mood, text: text, scale: scale, revision: revision)) }
    }
    public func stop(completion: @escaping () -> Void) {
        queue.async { [self] in
            running = false
            let pending = jobs; jobs.removeAll()
            pending.forEach { $0.cancel() }
            completion()
        }
    }
}
