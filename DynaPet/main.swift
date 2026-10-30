import AppKit
import SwiftUI
import IOKit.ps
import ApplicationServices
import ServiceManagement
import UniformTypeIdentifiers

// Local-only companion. Optional window OCR uses ScreenCaptureKit; no network, chat database or keystroke capture.
// Mood rules and snapshot types live in DynaPetNative/Sources/PetCore.

func axValue(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
    AXUIElementSetMessagingTimeout(e, 0.12)
    var out: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, key as CFString, &out) == .success ? out : nil
}
func axChildren(_ e: AXUIElement, _ key: String = kAXChildrenAttribute) -> [AXUIElement] {
    axValue(e, key) as? [AXUIElement] ?? []
}
func appElement(_ a: NSRunningApplication) -> AXUIElement {
    let e = AXUIElementCreateApplication(a.processIdentifier)
    AXUIElementSetMessagingTimeout(e, 0.12)
    return e
}
final class Sensors {
    var previous: [UInt64]?
    var smooth = 0.0
    var awakeSince = Date()
    func cpu() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return smooth }
        let now = [UInt64(info.cpu_ticks.0), UInt64(info.cpu_ticks.1), UInt64(info.cpu_ticks.2), UInt64(info.cpu_ticks.3)]
        defer { previous = now }
        guard let old = previous else { return smooth }
        let delta = zip(now, old).map { $0 >= $1 ? $0 - $1 : 0 }
        let total = delta.reduce(0, +)
        if total > 0 { smooth = smooth * 0.55 + (100 * Double(total - delta[2]) / Double(total)) * 0.45 }
        return smooth
    }
    func battery() -> (Int?, Bool) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, false) }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let ac = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return (Int(Double(cur) / Double(max) * 100), ac)
        }
        return (nil, false)
    }
    func sample(deep: Bool, messages: Bool) -> Snapshot {
        var s = Snapshot()
        s.cpu = cpu(); (s.battery, s.charging) = battery()
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
        s.apps = apps.count
        s.front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "桌面"
        s.idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        s.awake = Date().timeIntervalSince(awakeSince)
        guard deep && AXIsProcessTrusted() else { return s }
        var windows = 0, folders = 0, docs = 0
        for app in apps {
            let ws = axChildren(appElement(app), kAXWindowsAttribute)
            windows += ws.count
            if app.bundleIdentifier == "com.apple.finder" { folders += ws.count }
            for w in ws where axValue(w, kAXDocumentAttribute) != nil { docs += 1 }
        }
        s.windows = windows; s.folders = folders; s.documents = docs
        if messages {
            // Dock badges are unread indicators, not a count of all received messages.
            if let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
                var budget = 180
                walk(appElement(dock), depth: 0, budget: &budget) { e in
                    if let badge = axValue(e, "AXStatusLabel") as? String {
                        let digits = badge.filter(\.isNumber)
                        if let value = Int(digits) { s.badges += value }
                    }
                }
            }
            // Only accessibility text exposed by currently visible notification UI.
            if let center = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first {
                var budget = 160
                var texts: [String] = []
                walk(appElement(center), depth: 0, budget: &budget) { e in
                    guard (axValue(e, kAXRoleAttribute) as? String) == kAXStaticTextRole else { return }
                    if let t = axValue(e, kAXValueAttribute) as? String, !t.isEmpty, t.count < 600 { texts.append(t) }
                }
                s.notificationNodes = texts.count
                s.notification = Array(NSOrderedSet(array: texts).array as? [String] ?? []).prefix(10).joined(separator: " · ")
            }
        }
        return s
    }
    func walk(_ e: AXUIElement, depth: Int, budget: inout Int, body: (AXUIElement) -> Void) {
        guard depth < 7 && budget > 0 else { return }
        budget -= 1; body(e)
        for child in axChildren(e) { walk(child, depth: depth + 1, budget: &budget, body: body) }
    }
}

final class PetModel: ObservableObject {
    @Published var mood: Mood = .welcome
    @Published var text = "你好呀，我是 DynaPet！"
    @Published var snapshot = Snapshot()
    @Published var details = false
    @Published var animate = true {
        didSet {
            if animate { animationPausedDuration += Date().timeIntervalSinceReferenceDate - animationPausedAt }
            else { animationPausedAt = Date().timeIntervalSinceReferenceDate }
        }
    }
    var animationStartedAt = Date().timeIntervalSinceReferenceDate
    var animationPausedAt = Date().timeIntervalSinceReferenceDate
    var animationPausedDuration = 0.0
    func restartAnimation() {
        animationStartedAt = Date().timeIntervalSinceReferenceDate
        animationPausedDuration = 0
        if !animate { animationPausedAt = animationStartedAt }
    }
    @Published var messages = UserDefaults.standard.bool(forKey: "messages")
    @Published var trusted = AXIsProcessTrusted()
    @Published var loginStatus = ""
    @Published var scale: Double = {
        let saved = UserDefaults.standard.double(forKey: "scale")
        return [0.75, 1.0, 1.25].contains(saved) ? saved : 1
    }()
    let sensors = Sensors()
    let queue = DispatchQueue(label: "local.dynapet.sensors", qos: .utility)
    var pending = false, tick = 0, greetingUntil = Date().addingTimeInterval(14), touchedUntil = Date.distantPast
    @Published var inbox = MessageScan()
    @Published var ocrEnabled = UserDefaults.standard.bool(forKey: "windowOCR")
    @Published var capturePermission = CGPreflightScreenCaptureAccess()
    let messengerMonitor = MessengerMonitor()
    let fastMessageMonitor = RealtimeMessengerMonitor()
    var arrivalLedger = MessageArrivalLedger()
    var messageBusy = false, contentBusy = false, messageGeneration = 0, fastRescanWanted = false
    var messageTimer: Timer?
    var messageEvents: MessageEventBridge?
    var eventWork: DispatchWorkItem?
    var lastSubscriptionRefresh = Date.distantPast
    var subscriptionCount = 0
    var lastMessageAlerts: [Messenger: (Date, String)] = [:]
    @Published var messageStatus = "消息监听初始化中"
    @Published var messageSimulation = false
    var lastChange = Date.distantPast, lastBadge = 0, lastNotification = ""
    var screenTimeout = 300.0, sleeping = false
    var forced: Mood?
    var timer: Timer?
    var observers: [NSObjectProtocol] = []
    init() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.sleeping = true; self?.suspendMessageReads(); self?.set(.sleepy, "晚安，等你回来。"); self?.text = "晚安，等你回来。" })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.welcome() })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.welcome() })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.sleeping = true; self?.suspendMessageReads() })
        let events = MessageEventBridge { [weak self] in self?.requestFastMessageScan() }
        events.subscriptionReport = { [weak self] count in self?.subscriptionCount = count }
        messageEvents = events
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.messages, !self.sleeping else { return }
                Task { await self.fastMessageMonitor.reset() }
                self.messageEvents?.rebuild(); self.requestFastMessageScan()
            })
        }
        let fastTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.fastMessageTick() }
        fastTimer.tolerance = 0.04; RunLoop.main.add(fastTimer, forMode: .common); messageTimer = fastTimer
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        synchronizeMessageListeners()
        fastMessageTick()
        queue.async { [weak self] in
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); p.arguments = ["-g", "custom"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            do { try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                let str = String(data: data, encoding: .utf8) ?? ""
                // Match the current power-source block rather than guessing a universal timeout.
                DispatchQueue.main.async { self?.updateTimeout(str) }
            } catch {}
        }
        refresh()
    }
    func updateTimeout(_ output: String) {
        let b = sensors.battery()
        let marker = b.1 ? "AC Power:" : "Battery Power:"
        let block = output.components(separatedBy: marker).last ?? output
        if let line = block.components(separatedBy: .newlines).first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("displaysleep ") }), let minutes = Double(line.split(whereSeparator: \.isWhitespace).last ?? "") { screenTimeout = minutes * 60 }
    }
    func welcome() {
        sleeping = false; queue.async { self.sensors.awakeSince = Date() }; greetingUntil = Date().addingTimeInterval(14); forced = nil
        restartAnimation(); mood = .welcome; text = "你回来啦！刚刚休息得好吗？"; synchronizeMessageListeners(); requestFastMessageScan(); refresh()
    }
    func refresh() {
        guard !sleeping, !pending else { return }
        pending = true; tick += 1
        capturePermission = CGPreflightScreenCaptureAccess()
        if messages && tick % 2 == 1 { refreshMessageContent() }
        let deep = tick % 4 == 1
        queue.async { [weak self] in
            guard let self else { return }
            let value = self.sensors.sample(deep: deep, messages: false)
            DispatchQueue.main.async {
                self.pending = false
                var s = value
                if !deep { s.windows = self.snapshot.windows; s.folders = self.snapshot.folders; s.documents = self.snapshot.documents; s.badges = self.snapshot.badges; s.notification = self.snapshot.notification; s.notificationNodes = self.snapshot.notificationNodes }
                self.snapshot = s
                guard !self.sleeping else { return }
                if Date() < self.touchedUntil { return }
                if let forced = self.forced { self.set(forced, "动作预览 · \(forced.title)"); return }
                let d = decide(s, screenTimeout: self.screenTimeout, greeting: Date() < self.greetingUntil)
                if d.mood == self.mood || Date().timeIntervalSince(self.lastChange) > 9 || d.mood == .low || d.mood == .welcome { self.set(d.mood, d.text) }
            }
        }
    }
    func synchronizeMessageListeners() {
        let authorized = AXIsProcessTrusted()
        if trusted && !authorized {
            messageGeneration += 1; arrivalLedger.reset(); inbox = MessageScan(); lastMessageAlerts.removeAll()
            Task { await messengerMonitor.reset(); await fastMessageMonitor.reset() }
        }
        trusted = authorized
        messageEvents?.setActive(messages && trusted && !sleeping)
        lastSubscriptionRefresh = Date()
    }
    func suspendMessageReads() {
        messageGeneration += 1; eventWork?.cancel(); eventWork = nil; messageEvents?.setActive(false)
        for i in inbox.sources.indices { inbox.sources[i].preview = ""; inbox.sources[i].previewOrigin = "" }
        Task { await messengerMonitor.reset(); await fastMessageMonitor.reset() }
    }
    func fastMessageTick() {
        guard messages, !sleeping, !messageSimulation else {
            if !messages { messageStatus = "消息感知关闭" }
            return
        }
        if AXIsProcessTrusted() != trusted || Date().timeIntervalSince(lastSubscriptionRefresh) > 20 { synchronizeMessageListeners() }
        refreshMessages()
    }
    func requestFastMessageScan() {
        guard messages, !sleeping, !messageSimulation, eventWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.eventWork = nil; self?.refreshMessages() }
        eventWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
    }
    func refreshMessages() {
        guard messages, !sleeping, !messageSimulation else { return }
        if messageBusy { fastRescanWanted = true; return }
        messageBusy = true
        let monitor = fastMessageMonitor, generation = messageGeneration
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let packet = await monitor.poll()
            await MainActor.run {
                self.messageBusy = false
                guard self.messages, !self.sleeping, !self.messageSimulation, self.messageGeneration == generation else { self.fastRescanWanted = false; return }
                self.applyMessagePacket(packet)
                if self.fastRescanWanted { self.fastRescanWanted = false; self.requestFastMessageScan() }
            }
        }
    }
    func applyMessagePacket(_ packet: FastMessagePacket) {
        let arrivals = arrivalLedger.ingest(packet)
        let now = Date()
        for alert in arrivals { lastMessageAlerts[alert.source] = (now, alert.cause) }
        var sources = packet.sources
        for i in sources.indices {
            let source = sources[i].messenger
            if let old = inbox.sources.first(where: { $0.messenger == source }), packet.trusted {
                sources[i].ocrStatus = old.ocrStatus
                sources[i].preview = old.preview; sources[i].previewOrigin = old.previewOrigin
                sources[i].visibleMarkedMessages = old.visibleMarkedMessages
                if sources[i].unread == nil && old.countOrigin.contains("软件未读标签") {
                    // A slow observation is not claimed to be a fresh total after the fast read failed.
                    sources[i].status += " · 详情待后台补充"
                }
            }
            if let notice = packet.notices.last(where: { $0.source == source }) {
                sources[i].preview = notice.content; sources[i].previewOrigin = "系统通知"
            }
            sources[i].observedNotifications = arrivalLedger.captured[source, default: 0]
            if let last = lastMessageAlerts[source] { sources[i].lastAlertAt = last.0; sources[i].alertOrigin = last.1 }
        }
        inbox.sources = sources
        messageStatus = messageSimulation ? "演示模式，不代表真实消息已接通" : packet.trusted ? "事件订阅 \(subscriptionCount) 项 · 0.5 秒补查 · 上次扫描 \(packet.milliseconds) ms" : "辅助功能未授权，无法监听通知和角标"
        guard !arrivals.isEmpty else { return }
        // Arrival alerts take priority over greetings, normal metrics and manual expression previews.
        touchedUntil = now.addingTimeInterval(8)
        let urgent = arrivals.contains { alert in
            guard let content = alert.notice?.content.lowercased() else { return false }
            return ["紧急", "尽快", "urgent", "截止"].contains(where: { content.contains($0) })
        }
        let happy = arrivals.contains { alert in
            guard let content = alert.notice?.content else { return false }
            return ["谢谢", "恭喜", "通过", "成功"].contains(where: { content.contains($0) })
        }
        let names = arrivals.map { alert -> String in
            let source = sources.first { $0.messenger == alert.source }
            let count = source?.unread.map { "（未读 \($0)\(source?.atLeast == true ? "+" : "") 条）" } ?? ""
            return "\(alert.source.rawValue)来消息了\(count)"
        }
        set(urgent ? .hot : happy ? .happy : .message, names.joined(separator: "；") + "！")
    }
    func refreshMessageContent() {
        guard !contentBusy, messages, !sleeping, !messageSimulation else { return }
        contentBusy = true
        let monitor = messengerMonitor, ocr = ocrEnabled, generation = messageGeneration
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let content = await monitor.scan(useOCR: ocr)
            await MainActor.run {
                self.contentBusy = false
                guard self.messages, !self.sleeping, !self.messageSimulation, self.messageGeneration == generation else { return }
                for slow in content.sources {
                    guard let i = self.inbox.sources.firstIndex(where: { $0.messenger == slow.messenger }) else { continue }
                    // Background text updates can never block an arrival or create a fake new-message event.
                    if !slow.preview.isEmpty {
                        self.inbox.sources[i].preview = slow.preview; self.inbox.sources[i].previewOrigin = slow.previewOrigin
                    }
                    self.inbox.sources[i].ocrStatus = slow.ocrStatus
                    self.inbox.sources[i].visibleMarkedMessages = slow.visibleMarkedMessages
                    if self.inbox.sources[i].unread == nil && slow.countOrigin.contains("未读标签"), let n = slow.unread {
                        self.inbox.sources[i].unread = n; self.inbox.sources[i].countOrigin = slow.countOrigin + "（后台读取）"
                    }
                }
            }
        }
    }
    func simulateArrival(_ source: Messenger) {
        guard !messageSimulation else { return }
        let savedLedger = arrivalLedger, savedAlerts = lastMessageAlerts, generation = messageGeneration
        messageSimulation = true
        var baseline = FastMessagePacket(); baseline.trusted = true
        for i in baseline.sources.indices { baseline.sources[i].running = true; baseline.sources[i].unread = 0; baseline.sources[i].countOrigin = "演示数据" }
        arrivalLedger.reset(); applyMessagePacket(baseline)
        var arrival = baseline
        if let i = arrival.sources.firstIndex(where: { $0.messenger == source }) { arrival.sources[i].unread = 1 }
        arrival.notices = [Notice(source: source, content: "演示通知，不是真实聊天消息", identifier: UUID().uuidString)]
        applyMessagePacket(arrival); text = "【演示】" + text; details = true
        for key in lastMessageAlerts.keys { lastMessageAlerts[key]?.1 = "演示通知（非真实消息）" }
        for i in inbox.sources.indices where inbox.sources[i].lastAlertAt != nil { inbox.sources[i].alertOrigin = "演示通知（非真实消息）" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in
            guard let self else { return }
            self.messageSimulation = false
            if self.messageGeneration == generation {
                self.arrivalLedger = savedLedger; self.lastMessageAlerts = savedAlerts
            }
            self.inbox = MessageScan(); self.touchedUntil = .distantPast; self.requestFastMessageScan()
        }
    }
    func toggleOCR() {
        ocrEnabled.toggle(); UserDefaults.standard.set(ocrEnabled, forKey: "windowOCR")
        messageGeneration += 1
        if ocrEnabled {
            if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
            messages = true; UserDefaults.standard.set(true, forKey: "messages")
        } else {
            inbox = MessageScan(); Task { await messengerMonitor.reset() }
        }
        capturePermission = CGPreflightScreenCaptureAccess(); details = true
    }
    func captureSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
    func set(_ m: Mood, _ t: String) { if mood != m { lastChange = Date(); restartAnimation() }; withAnimation(.easeInOut(duration: 0.18)) { mood = m; text = t } }
    func pet() { restartAnimation(); forced = nil; touchedUntil = Date().addingTimeInterval(7); set(.shy, "嘿嘿，被你摸摸啦～") }
    func permission() { let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary; _ = AXIsProcessTrustedWithOptions(options) }
    func toggleMessages() {
        messages.toggle(); messageGeneration += 1
        UserDefaults.standard.set(messages, forKey: "messages")
        if messages { permission() }
        else { inbox = MessageScan(); arrivalLedger.reset(); lastMessageAlerts.removeAll(); eventWork?.cancel(); eventWork = nil; Task { await messengerMonitor.reset(); await fastMessageMonitor.reset() } }
        synchronizeMessageListeners(); requestFastMessageScan()
    }
    func login() {
        do { if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister(); loginStatus = "已关闭登录启动" }
             else { try SMAppService.mainApp.register(); loginStatus = SMAppService.mainApp.status == .enabled ? "已开启登录启动" : "请在系统设置中允许登录启动"; if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() } }
        } catch { loginStatus = "登录启动失败：\(error.localizedDescription)" }
    }
}

struct PetView: View {
    @ObservedObject var model: PetModel
    let library: MotionLibrary
    var body: some View {
        VStack(spacing: 7) {
            if model.details { dashboard.transition(.opacity.combined(with: .move(edge: .bottom))) }
            Text(model.text).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.primary)
                .multilineTextAlignment(.center).padding(.horizontal, 13).padding(.vertical, 9)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
                .frame(maxWidth: 235).fixedSize(horizontal: false, vertical: true)
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !model.animate)) { timeline in
                let now = model.animate ? timeline.date.timeIntervalSinceReferenceDate : model.animationPausedAt
                let t = library.dynamic ? max(0, now - max(model.animationStartedAt, library.loadedAt) - model.animationPausedDuration) : (model.animate ? now : 0)
                MotionSprite(library: library, mood: model.mood, time: t, scale: model.scale)
            }
            HStack(spacing: 6) {
                Circle().fill(model.mood == .low ? .orange : .mint).frame(width: 5, height: 5)
                Text(model.mood.title)
                if let b = model.snapshot.battery { Text("· \(model.snapshot.charging ? "⚡" : "")\(b)%") }
            }.font(.system(size: 10, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 5).background(.regularMaterial, in: Capsule())
        }.padding(14).frame(width: 290, height: model.details ? 650 : 200 * model.scale + 120, alignment: .bottom)
        .onChange(of: model.details) { resizePanel() }
        .onChange(of: model.scale) { resizePanel() }
    }

    var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                HStack { Text("DynaPet · 本机感知").fontWeight(.semibold); Spacer(); Text(model.trusted ? "辅助功能已授权" : "待辅助功能授权").foregroundStyle(.secondary) }
                ProgressView(value: model.snapshot.cpu, total: 100).tint(model.snapshot.cpu > 70 ? .orange : .mint)
                Text("CPU \(Int(model.snapshot.cpu))% · 软件 \(model.snapshot.apps) · 本次 \(Int(model.snapshot.awake / 60)) 分钟")
                Text("窗口 \(count(model.snapshot.windows)) · 文件夹 \(count(model.snapshot.folders)) · 文档 \(count(model.snapshot.documents))").foregroundStyle(.secondary)
                if model.messages || model.messageSimulation {
                    Divider()
                    Text(model.messageStatus).foregroundStyle(.secondary)
                    if model.messageSimulation { Text("正在演示：未读数非真实数据").foregroundStyle(.orange) }
                    Text("已提供的未读计数合计：\(model.inbox.sources.compactMap(\.unread).reduce(0, +)) · 未提供者不计入")
                    ForEach(model.inbox.sources) { source in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { Text(source.messenger.rawValue).fontWeight(.semibold); Spacer(); Text(source.running ? "运行中" : "未运行").foregroundStyle(.secondary) }
                            Text(source.unreadLabel)
                            if let n = source.visibleMarkedMessages { Text("可见会话条数标记：\(n)（非全量）").foregroundStyle(.secondary) }
                            Text("本次新捕获通知 \(source.observedNotifications) · \(source.status)").foregroundStyle(.secondary)
                            if let date = source.lastAlertAt { Text("上次提醒 \(date.formatted(date: .omitted, time: .standard)) · \(source.alertOrigin)").foregroundStyle(.secondary) }
                            if model.ocrEnabled && !source.ocrStatus.isEmpty { Text(source.ocrStatus).foregroundStyle(.secondary) }
                            if !source.preview.isEmpty { Text("\(source.previewOrigin)：\(source.preview)").lineLimit(3).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                        Divider()
                    }
                    Text(model.ocrEnabled ? (model.capturePermission ? "窗口 OCR：已授权 · 仅三软件" : "窗口 OCR：待屏幕录制授权") : "窗口 OCR：关闭").foregroundStyle(.secondary)
                } else { Text("消息感知：关闭").foregroundStyle(.secondary) }
                if !model.loginStatus.isEmpty { Text(model.loginStatus).foregroundStyle(.secondary) }
            }.font(.system(size: 10))
        }.frame(maxHeight: 280).padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
    func resizePanel() {
        guard let w = NSApp.windows.first(where: { $0 is PetPanel }) else { return }
        let manager: any WindowManager = AppKitWindowManager(window: w)
        var bounds = manager.bounds
        let height = model.details ? 650 : 200 * model.scale + 120
        bounds.origin.y -= height - bounds.height
        bounds.height = height
        manager.setBounds(bounds)
    }
    func count(_ n: Int?) -> String { n.map(String.init) ?? "待授权" }
}

// Keep tracking outside SwiftUI: local gesture coordinates move with this window,
// and observable model updates must not rebuild an open submenu.
final class PetHostingView: NSHostingView<PetView> {
    let model: PetModel
    init(model: PetModel, library: MotionLibrary) {
        self.model = model
        super.init(rootView: PetView(model: model, library: library))
        registerForDraggedTypes([.fileURL])
    }
    required init(rootView: PetView) {
        model = rootView.model
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = NSEvent.mouseLocation
        window.performDrag(with: event)
        let end = NSEvent.mouseLocation
        if hypot(end.x - start.x, end.y - start.y) < 4 { model.pet() }
    }
    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(makeMenu(), with: event, for: self)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              let app = NSApp.delegate as? AppDelegate else { return false }
        return app.importTheme(urls)
    }
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let notice = NSMenuItem(title: "DynaPet · 非商用", action: nil, keyEquivalent: "")
        notice.isEnabled = false; menu.addItem(notice); menu.addItem(.separator())
        func add(_ title: String, to parent: NSMenu = menu, action: @escaping () -> Void) {
            parent.addItem(PetMenuItem(title: title, handler: action))
        }
        func submenu(_ title: String) -> NSMenu {
            let child = NSMenu(title: title)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = child; menu.addItem(item)
            return child
        }
        add(window?.isVisible == true ? "隐藏桌宠" : "显示桌宠") {
            guard let window = self.window else { return }
            if window.isVisible { window.orderOut(nil) } else { window.orderFrontRegardless() }
        }
        add(model.details ? "收起状态面板" : "展开状态面板") { self.model.details.toggle(); self.window?.orderFrontRegardless() }
        add("摸摸") { self.model.pet() }
        let moods = submenu("动作预览")
        add("自动感知", to: moods) { self.model.forced = nil; self.model.refresh() }
        for mood in Mood.allCases {
            add(mood.title, to: moods) { self.model.forced = mood; self.model.set(mood, "动作预览 · \(mood.title)") }
        }
        add(model.animate ? "暂停动作" : "恢复动作") { self.model.animate.toggle() }
        let sizes = submenu("大小")
        for scale in [0.75, 1.0, 1.25] {
            add("\(Int(scale * 100))%", to: sizes) {
                self.model.scale = scale; UserDefaults.standard.set(scale, forKey: "scale")
            }
        }
        menu.addItem(.separator())
        add("导入角色图片…") { (NSApp.delegate as? AppDelegate)?.chooseTheme() }
        add("恢复内置角色") { (NSApp.delegate as? AppDelegate)?.restoreTheme() }
        add("导入主题包…") { (NSApp.delegate as? AppDelegate)?.chooseThemeFolder() }
        add("打开角色文件夹") {
            try? FileManager.default.createDirectory(at: ThemeImport.root, withIntermediateDirectories: true)
            NSWorkspace.shared.open(ThemeImport.root)
        }
        add("关于 DynaPet 与许可") {
            let alert = NSAlert(); alert.messageText = "DynaPet · 非商用源码公开"
            alert.informativeText = "DynaPet 是跨平台桌宠引擎。自有代码沿用 PolyForm Noncommercial 1.0.0 非商用许可。演示主题与用户主题的图片权利独立于引擎代码，详见 DemoTheme/NOTICE.md。"
            alert.runModal()
        }
        add("授权辅助功能（窗口 / 文件统计）") { self.model.permission() }
        add(model.messages ? "关闭三软件消息感知" : "开启三软件消息感知") { self.model.toggleMessages() }
        let demos = submenu("消息提醒演示（非真实消息）")
        for source in Messenger.allCases { add(source.rawValue, to: demos) { self.model.simulateArrival(source) } }
        add(model.ocrEnabled ? "关闭窗口文字识别" : "开启窗口文字识别（需屏幕录制）") { self.model.toggleOCR() }
        add("打开屏幕录制权限设置") { self.model.captureSettings() }
        add(SMAppService.mainApp.status == .enabled ? "关闭登录时启动" : "开启登录时启动") { self.model.login() }
        menu.addItem(.separator())
        add("退出 DynaPet") { NSApp.terminate(nil) }
        return menu
    }
}
final class PetMenuItem: NSMenuItem {
    let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }
}

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func mouseDown(with event: NSEvent) { performDrag(with: event) }
}
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    var panel: PetPanel!, model: PetModel!, status: NSStatusItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "io.github.pantalone800.dynapet").count > 1 { NSApp.terminate(nil); return }
        model = PetModel()
        var library = MotionLibrary()
        if !library.ready { UserDefaults.standard.removeObject(forKey: "themeFolder"); library = MotionLibrary(directory: nil) }
        guard library.ready else { NSLog("Missing motion resources"); NSApp.terminate(nil); return }
        panel = PetPanel(contentRect: NSRect(x: 0, y: 0, width: 290, height: 200 * model.scale + 120), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false; panel.delegate = self
        panel.contentView = PetHostingView(model: model, library: library)
        position(); panel.orderFrontRegardless()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "DynaPet"
        let menu = (panel.contentView as! PetHostingView).makeMenu()
        menu.delegate = self
        status.menu = menu
        NotificationCenter.default.addObserver(self, selector: #selector(reset), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        if CommandLine.arguments.contains("--enable-login") && SMAppService.mainApp.status != .enabled { model.login() }
        // Local diagnostic broadcasts are opt-in, never an ambient production endpoint.
        if CommandLine.arguments.contains("--allow-local-diagnostics") {
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(writeDiagnostics), name: NSNotification.Name("io.github.pantalone800.dynapet.requestDiagnostics"), object: nil)
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(messageCapabilities), name: NSNotification.Name("io.github.pantalone800.dynapet.requestMessageCapabilities"), object: nil)
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(testArrival), name: NSNotification.Name("io.github.pantalone800.dynapet.testArrival"), object: nil)
        }
        if CommandLine.arguments.contains("--diagnostics") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.writeDiagnostics() }
        }
        if CommandLine.arguments.contains("--test-arrival") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.model.simulateArrival(.wechat) }
        }
        if CommandLine.arguments.contains("--request-accessibility") { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.model.permission() } }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let view = panel.contentView as? PetHostingView else { return }
        let fresh = view.makeMenu()
        menu.removeAllItems()
        for item in fresh.items { fresh.removeItem(item); menu.addItem(item) }
    }
    func chooseTheme() {
        let picker = NSOpenPanel(); picker.allowedContentTypes = [.image]; picker.allowsMultipleSelection = true
        picker.message = "选择 1～11 张角色图。单图复用于所有心情；idle、happy 等文件名可分别指定。"
        if picker.runModal() == .OK { _ = importTheme(picker.urls) }
    }
    func importTheme(_ urls: [URL]) -> Bool {
        do {
            let name = try ThemeImport.make(urls)
            let library = MotionLibrary(directory: ThemeImport.root.appendingPathComponent(name))
            guard library.ready else { return false }
            model.restartAnimation()
            UserDefaults.standard.set(name, forKey: "themeFolder")
            (panel.contentView as? PetHostingView)?.rootView = PetView(model: model, library: library)
            return true
        } catch {
            let alert = NSAlert(); alert.messageText = "角色导入失败，原角色保持不变"; alert.informativeText = error.localizedDescription; alert.runModal()
            return false
        }
    }
    func chooseThemeFolder() {
        let picker = NSOpenPanel(); picker.canChooseDirectories = true; picker.canChooseFiles = false
        picker.message = "选择图片文件夹，或含 theme.json 的完整主题目录。"
        if picker.runModal() == .OK { _ = importTheme(picker.urls) }
    }
    func restoreTheme() {
        model.restartAnimation()
        UserDefaults.standard.removeObject(forKey: "themeFolder")
        (panel.contentView as? PetHostingView)?.rootView = PetView(model: model, library: MotionLibrary(directory: nil))
    }
    @objc func messageCapabilities() {
        guard let model else { return }
        Task {
            let dockNodes = await model.fastMessageMonitor.inspectDockCapabilities()
            let menuNodes = await model.fastMessageMonitor.inspectStatusMenuCapabilities()
            let nodes = dockNodes + menuNodes
            let data: [String: Any] = ["generatedAt": Date().timeIntervalSince1970, "nodes": nodes]
            if let json = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) {
                try? json.write(to: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DynaPet-message-capabilities.json"), options: .atomic)
            }
        }
    }
    @objc func writeDiagnostics() {
        guard let model else { return }
        let data: [String: Any] = ["generatedAt": Date().timeIntervalSince1970, "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown", "accessibility": model.trusted, "screenCapture": model.capturePermission, "ocrEnabled": model.ocrEnabled, "login": SMAppService.mainApp.status.rawValue, "messageStatus": model.messageStatus, "eventSubscriptions": model.subscriptionCount, "messagesEnabled": model.messages, "simulation": model.messageSimulation, "mood": model.mood.rawValue, "animatedBustClips": 11, "sources": model.inbox.sources.map { source -> [String: Any] in
            ["name": source.messenger.rawValue, "running": source.running, "unread": source.unread as Any? ?? NSNull(), "countOrigin": source.countOrigin, "status": source.status, "previewCharacters": source.preview.count, "redDot": source.redDot, "capturedNotifications": source.observedNotifications, "lastAlert": source.lastAlertAt?.timeIntervalSince1970 as Any? ?? NSNull()]
        }]
        if let json = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DynaPet-diagnostics.json"), options: .atomic)
        }
    }
    @objc func testArrival() {
        model?.simulateArrival(.wechat)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let model = self.model, model.messageSimulation else { return }
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let counts = model.inbox.sources.map { ["name": $0.messenger.rawValue, "unread": $0.unread as Any? ?? NSNull(), "origin": $0.countOrigin] as [String: Any] }
            let success = model.mood == .message && model.text.hasPrefix("【演示】微信来消息了") && model.inbox.sources.first(where: { $0.messenger == .wechat })?.unread == 1
            let report: [String: Any] = ["generatedAt": Date().timeIntervalSince1970, "simulation": true, "passed": success, "mood": model.mood.rawValue, "bubble": model.text, "sources": counts]
            if let json = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? json.write(to: root.appendingPathComponent("DynaPet-arrival-demo.json"), options: .atomic) }
            if let view = self.panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: root.appendingPathComponent("DynaPet-arrival-demo.png"), options: .atomic) }
            }
        }
    }
    func position() {
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        var origin = NSPoint(x: v.midX - panel.frame.width / 2, y: v.minY + 40)
        if UserDefaults.standard.bool(forKey: "positionSaved") { origin = NSPoint(x: UserDefaults.standard.double(forKey: "petX"), y: UserDefaults.standard.double(forKey: "petY")) }
        let proposed = NSRect(origin: origin, size: panel.frame.size)
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersection(proposed).width > 80 && $0.visibleFrame.intersection(proposed).height > 120 }) { origin = NSPoint(x: v.midX - panel.frame.width / 2, y: v.minY + 40) }
        panel.setFrameOrigin(origin)
    }
    func windowDidMove(_ notification: Notification) { UserDefaults.standard.set(panel.frame.minX, forKey: "petX"); UserDefaults.standard.set(panel.frame.minY, forKey: "petY"); UserDefaults.standard.set(true, forKey: "positionSaved") }
    @objc func toggle() { if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() } }
    @objc func details() { model.details.toggle(); panel.orderFrontRegardless() }
    @objc func reset() { UserDefaults.standard.set(false, forKey: "positionSaved"); position(); panel.orderFrontRegardless() }
    @objc func permission() { model.permission() }
    @objc func messages() { model.toggleMessages(); model.details = true }
    @objc func captureSettings() { model.captureSettings() }
    @objc func ocr() { model.toggleOCR() }
    @objc func login() { model.login(); model.details = true }
    @objc func quit() { NSApp.terminate(nil) }
}

func selfTest() {
    let library = MotionLibrary(directory: nil)
    precondition(library.ready, "Packaged DemoTheme assets must load all 11 animations")
    print("PASS: packaged assets; 11 animations × 3 frames")
    do {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("dynapet-theme-check-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let image = library.clips[.idle]?.frames.first, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { preconditionFailure("Cannot prepare import fixture") }
        let input = temporary.appendingPathComponent("角色图.png")
        try png.write(to: input)
        let name = try ThemeImport.make([input], rootOverride: temporary)
        precondition(MotionLibrary(directory: temporary.appendingPathComponent(name)).ready)
        let imported = try ThemeImport.make([temporary.appendingPathComponent(name)], rootOverride: temporary)
        precondition(MotionLibrary(directory: temporary.appendingPathComponent(imported)).ready)
        print("PASS: single-image and folder import create 11 loadable states; existing themes untouched")
    } catch { preconditionFailure("Theme import self-test failed: \(error)") }
    var s = Snapshot()
    precondition(decide(s, screenTimeout: 300, greeting: true).mood == .welcome)
    s.battery = 10; precondition(decide(s, screenTimeout: 300, greeting: false).mood == .low)
    s.charging = true; s.cpu = 95; precondition(decide(s, screenTimeout: 300, greeting: false).mood == .dizzy)
    s.cpu = 65; precondition(decide(s, screenTimeout: 300, greeting: false).mood == .hot)
    s.cpu = 10; s.idle = 280; precondition(decide(s, screenTimeout: 300, greeting: false).mood == .sleepy)
    s.idle = 0; s.front = "Visual Studio Code"; precondition(decide(s, screenTimeout: 300, greeting: false).mood == .focus)
    s.front = "WPS Office"; precondition(decide(s, screenTimeout: 300, greeting: false).mood == .focus)
    s.front = "Finder"; precondition(decide(s, screenTimeout: 300, greeting: false).mood == .puzzled)
    s.front = "Safari"; precondition(decide(s, screenTimeout: 300, greeting: false).mood == .happy)
    s.charging = false; s.battery = 80; precondition(decide(s, screenTimeout: 300, greeting: false).mood == .idle)
    let sensors = Sensors(); let live = sensors.sample(deep: false, messages: false)
    print("PASS: 10 mood rules; live apps=\(live.apps), battery=\(String(describing: live.battery)), idle=\(Int(live.idle))s")
    print("loginStatus=\(SMAppService.mainApp.status.rawValue); accessibility=\(AXIsProcessTrusted())")
}
if CommandLine.arguments.contains("--message-capabilities") {
    DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("io.github.pantalone800.dynapet.requestMessageCapabilities"), object: nil, userInfo: nil, deliverImmediately: true)
}
else if CommandLine.arguments.contains("--request-diagnostics") {
    DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("io.github.pantalone800.dynapet.requestDiagnostics"), object: nil, userInfo: nil, deliverImmediately: true)
}
else if CommandLine.arguments.contains("--simulate-wechat") {
    DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("io.github.pantalone800.dynapet.testArrival"), object: nil, userInfo: nil, deliverImmediately: true)
}
else if CommandLine.arguments.contains("--render-motion"), CommandLine.arguments.count >= 3 {
    do { try MainActor.assumeIsolated { try renderMotionPreview(directory: URL(fileURLWithPath: CommandLine.arguments[2])) } }
    catch { fputs("Motion preview failed: \(error)\n", stderr); exit(1) }
}
else if CommandLine.arguments.contains("--self-test") { selfTest(); messageSelfTest(); realtimeMessageSelfTest() }
else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate; app.setActivationPolicy(.accessory); app.run()
}
