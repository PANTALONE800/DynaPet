import AppKit
import IOKit.ps
import ApplicationServices
import PetCore

/// Platform data collection only. Decisions stay in PetCore/PetController.
public final class MacPetEnvironment {
    private let queue = DispatchQueue(label: "pet.mac.environment", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var active = false, paused = false
    private var onSnapshot: ((Snapshot, Double) -> Void)?
    private var onSleep: (() -> Void)?, onWake: (() -> Void)?
    private var observers: [NSObjectProtocol] = [] // accessed on main only
    private var previous: [UInt64]?
    private var cpuSmooth = 0.0, screenTimeout = 300.0
    private var awakeSince = Date(), tick = 0
    private var cached = Snapshot()
    public init() {}
    public func start(onSnapshot: @escaping (Snapshot, Double) -> Void, onSleep: @escaping () -> Void, onWake: @escaping () -> Void) {
        queue.async { [self] in
            guard !active else { return }
            active = true; self.onSnapshot = onSnapshot; self.onSleep = onSleep; self.onWake = onWake
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 3, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.sample() }
            self.timer = timer; timer.resume()
            readScreenTimeout()
        }
        DispatchQueue.main.async { [self] in
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.queue.async { [weak self] in
                        guard let self, self.active, !self.paused else { return }
                        self.paused = true; self.onSleep?()
                    }
                })
            }
            for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.queue.async { [weak self] in
                        guard let self, self.active, self.paused else { return }
                        self.paused = false; self.awakeSince = Date(); self.onWake?(); self.sample()
                    }
                })
            }
        }
    }
    public func stop() {
        queue.async { [self] in
            active = false; timer?.cancel(); timer = nil
            onSnapshot = nil; onSleep = nil; onWake = nil
        }
        DispatchQueue.main.async { [self] in
            let center = NSWorkspace.shared.notificationCenter
            observers.forEach { center.removeObserver($0) }; observers.removeAll()
        }
    }
    private func cpu() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return cpuSmooth }
        let current = [UInt64(info.cpu_ticks.0), UInt64(info.cpu_ticks.1), UInt64(info.cpu_ticks.2), UInt64(info.cpu_ticks.3)]
        defer { previous = current }
        guard let previous else { return cpuSmooth }
        let delta = zip(current, previous).map { $0 >= $1 ? $0 - $1 : 0 }
        let total = delta.reduce(0, +)
        if total > 0 { cpuSmooth = cpuSmooth * 0.55 + 100 * Double(total - delta[2]) / Double(total) * 0.45 }
        return cpuSmooth
    }
    private func battery() -> (Int?, Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, false) }
        for source in list {
            guard let data = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = data[kIOPSCurrentCapacityKey] as? Int, let maximum = data[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return (Int(Double(current) / Double(maximum) * 100), data[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        return (nil, false)
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.03)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private func sample() {
        guard active, !paused else { return }
        tick += 1
        var value = Snapshot()
        value.cpu = cpu(); (value.battery, value.charging) = battery()
        let applications = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
        value.apps = applications.count
        value.front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "桌面"
        value.idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        value.awake = Date().timeIntervalSince(awakeSince)
        value.windows = cached.windows; value.folders = cached.folders; value.documents = cached.documents
        let trusted = AXIsProcessTrusted()
        if !trusted { value.windows = nil; value.folders = nil; value.documents = nil }
        if tick % 4 == 1 && trusted {
            var windows = 0, folders = 0, documents = 0
            let deadline = Date().addingTimeInterval(1)
            var complete = true
            for application in applications {
                guard Date() < deadline else { complete = false; break }
                let element = AXUIElementCreateApplication(application.processIdentifier)
                guard let list = attribute(element, kAXWindowsAttribute) as? [AXUIElement] else { complete = false; continue }
                windows += list.count
                if application.bundleIdentifier == "com.apple.finder" { folders += list.count }
                documents += list.filter { Date() < deadline && attribute($0, kAXDocumentAttribute) != nil }.count
            }
            if complete { value.windows = windows; value.folders = folders; value.documents = documents }
        }
        cached = value
        onSnapshot?(value, screenTimeout)
    }
    private func readScreenTimeout() {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); process.arguments = ["-g", "custom"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        do {
            try process.run(); DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: timeout)
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); timeout.cancel()
            let output = String(data: data, encoding: .utf8) ?? ""
            let block = output.components(separatedBy: battery().1 ? "AC Power:" : "Battery Power:").last ?? output
            if let line = block.components(separatedBy: .newlines).first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("displaysleep ") }),
               let minutes = Double(line.split(whereSeparator: \.isWhitespace).last ?? "") { screenTimeout = minutes * 60 }
        } catch { timeout.cancel() }
    }
}
