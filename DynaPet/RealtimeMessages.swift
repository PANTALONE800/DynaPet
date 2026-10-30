import AppKit
import ApplicationServices

// The fast channel never opens a chat window, runs OCR or awaits the content actor.
struct MessageAlert {
    var source: Messenger
    var cause: String
    var notice: Notice?
}
struct FastMessagePacket {
    var sources = Messenger.allCases.map { InboxSource(messenger: $0) }
    var notices: [Notice] = []
    var trusted = false
    var milliseconds = 0
    var completed = Date()
}
struct MessageArrivalLedger {
    private var seeded = false
    private var previousCounts: [Messenger: Int] = [:]
    private var previousDots: [Messenger: Bool] = [:]
    private var previousOrigins: [Messenger: String] = [:]
    private var seenNotices = Set<String>()
    private var noticeOrder: [String] = []
    private var lastAlert: [Messenger: Date] = [:]
    private(set) var captured: [Messenger: Int] = [:]
    mutating func reset() { self = MessageArrivalLedger() }
    mutating func ingest(_ packet: FastMessagePacket, now: Date = Date()) -> [MessageAlert] {
        guard packet.trusted else { reset(); return [] }
        var alerts: [Messenger: MessageAlert] = [:]
        for source in packet.sources {
            let origin = source.countOrigin.hasPrefix("顶部菜单栏") ? "menubar" : source.countOrigin.hasPrefix("Dock") ? "dock" : source.countOrigin
            let sameCounter = previousOrigins[source.messenger] == nil || previousOrigins[source.messenger] == origin
            if seeded, sameCounter, let n = source.unread, n > (previousCounts[source.messenger] ?? 0) {
                alerts[source.messenger] = MessageAlert(source: source.messenger, cause: "未读角标增加", notice: nil)
            }
            if seeded && source.redDot && source.badgeReadable && previousDots[source.messenger] != true {
                alerts[source.messenger] = MessageAlert(source: source.messenger, cause: "未读红点出现", notice: nil)
            }
            if let n = source.unread { previousCounts[source.messenger] = n; previousOrigins[source.messenger] = origin }
            else if !source.running { previousCounts.removeValue(forKey: source.messenger); previousOrigins.removeValue(forKey: source.messenger) }
            if source.badgeReadable || source.unread != nil { previousDots[source.messenger] = source.redDot }
            else if !source.running { previousDots.removeValue(forKey: source.messenger) }
        }
        for notice in packet.notices where !seenNotices.contains(notice.signature) {
            seenNotices.insert(notice.signature); noticeOrder.append(notice.signature)
            if seeded {
                captured[notice.source, default: 0] += 1
                alerts[notice.source] = MessageAlert(source: notice.source, cause: "新系统通知", notice: notice)
            }
        }
        if noticeOrder.count > 600 {
            for key in noticeOrder.prefix(noticeOrder.count - 600) { seenNotices.remove(key) }
            noticeOrder = Array(noticeOrder.suffix(600))
        }
        seeded = true
        return Messenger.allCases.compactMap { source in
            guard let alert = alerts[source] else { return nil }
            // A banner and its corresponding badge update often arrive in separate AX callbacks.
            if let last = lastAlert[source], now.timeIntervalSince(last) < 0.85 { return nil }
            lastAlert[source] = now
            return alert
        }
    }
}

private func fastValue(_ element: AXUIElement, _ key: String) -> (AXError, CFTypeRef?) {
    AXUIElementSetMessagingTimeout(element, 0.025)
    var out: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, key as CFString, &out)
    return (error, out)
}
private func fastString(_ element: AXUIElement, _ key: String) -> String {
    fastValue(element, key).1 as? String ?? ""
}
private func fastChildren(_ element: AXUIElement) -> [AXUIElement] {
    fastValue(element, kAXChildrenAttribute).1 as? [AXUIElement] ?? []
}
func messengerForApplication(_ app: NSRunningApplication) -> Messenger? {
    let bundle = app.bundleIdentifier?.lowercased() ?? ""
    return Messenger.allCases.first { source in
        bundle == source.bundle.lowercased() || (source == .ding && bundle.contains("dingtalk") && app.activationPolicy == .regular)
    }
}
func classifyMessengerDockItem(subrole: String, title: String, urlName: String) -> Messenger? {
    // Minimized chat windows have the same title as their app and appear later in Dock's child list.
    // They must never overwrite the real application's badge-bearing AXApplicationDockItem.
    guard subrole == "AXApplicationDockItem" else { return nil }
    let label = (title + " " + urlName).trimmingCharacters(in: .whitespacesAndNewlines)
    return Messenger.allCases.first { $0.matches(name: label) }
}
func dockMessenger(_ element: AXUIElement) -> Messenger? {
    let subrole = fastString(element, kAXSubroleAttribute)
    guard subrole == "AXApplicationDockItem" else { return nil }
    let title = fastString(element, kAXTitleAttribute)
    let urlName = (fastValue(element, kAXURLAttribute).1 as? URL)?.lastPathComponent ?? ""
    return classifyMessengerDockItem(subrole: subrole, title: title, urlName: urlName)
}
func numericDockBadge(_ text: String) -> (Int, Bool)? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let exact = exactBadge(value) { return exact }
    let pattern = #"^(\d{1,6})(\+?)\s*(?:(?:个|条)?\s*(?:未读|新)?\s*(?:通知|消息|项目)|(?:(?:new|unread)\s+)?(?:items?|messages?|notifications?))$"#
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]), let match = re.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)), let range = Range(match.range(at: 1), in: value), let count = Int(value[range]), let capped = Range(match.range(at: 2), in: value) else { return nil }
    return (count, !value[capped].isEmpty)
}
struct MenuUnreadReading {
    var count: Int?, atLeast = false, redDot = false, confirmed = true
    var origin = "顶部菜单栏计数"
}
struct MenuCounterMemory {
    private var last: [Messenger: MenuUnreadReading] = [:]
    private var emptySince: [Messenger: Date] = [:]
    mutating func update(_ source: Messenger, title: String, valid: Bool, at now: Date) -> MenuUnreadReading? {
        guard valid else { return nil }
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let (count, capped) = numericDockBadge(text) {
            let reading = MenuUnreadReading(count: count, atLeast: capped)
            last[source] = reading; emptySince.removeValue(forKey: source); return reading
        }
        if ["●", "•", "新消息", "有未读消息", "有新消息", "unread", "new message"].contains(text.lowercased()) {
            let reading = MenuUnreadReading(count: nil, redDot: true, origin: "顶部菜单栏未读标记")
            last[source] = reading; emptySince.removeValue(forKey: source); return reading
        }
        if text.isEmpty, var previous = last[source] {
            // WeChat may blink its menu icon/title. A short blank must not become 0 -> N -> 0.
            let start = emptySince[source] ?? now; emptySince[source] = start
            if now.timeIntervalSince(start) >= 2 {
                previous.count = previous.count == nil ? nil : 0; previous.redDot = false; previous.confirmed = true
                previous.origin = "顶部菜单栏计数（已清空）"; last[source] = previous
            } else { previous.confirmed = false; previous.origin = "顶部菜单栏计数（防闪烁确认）" }
            return previous
        }
        return nil
    }
    mutating func reset(_ source: Messenger? = nil) {
        if let source { last.removeValue(forKey: source); emptySince.removeValue(forKey: source) }
        else { last.removeAll(); emptySince.removeAll() }
    }
}
private func messengerExtras(_ application: NSRunningApplication) -> (AXUIElement?, [AXUIElement]) {
    let root = AXUIElementCreateApplication(application.processIdentifier)
    guard let value = fastValue(root, "AXExtrasMenuBar").1, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (nil, []) }
    let bar = value as! AXUIElement
    let items = fastChildren(bar).filter { fastString($0, kAXRoleAttribute) == kAXMenuBarItemRole }
    return (bar, items)
}
private struct NotificationBranch {
    var role: String, texts: [String], identifier: String
    var children: [NotificationBranch]
    var allText: [String] { texts + children.flatMap(\.allText) }
}
private func headerSource(_ text: String) -> Messenger? {
    let s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    for (source, names) in [(Messenger.wechat, ["微信", "wechat", "weixin"]), (.ding, ["钉钉", "dingtalk"]), (.qq, ["qq"])] {
        for name in names where s == name || s.hasPrefix(name + "\n") || s.hasPrefix(name + "，") || s.hasPrefix(name + ",") || s.hasPrefix(name + " ") || s.hasPrefix("来自" + name) { return source }
    }
    return nil
}
actor RealtimeMessengerMonitor {
    private var dockItems: [Messenger: AXUIElement] = [:]
    private var statusSupported = Set<Messenger>()
    private var menuItems: [Messenger: [AXUIElement]] = [:]
    private var menuPids: [Messenger: pid_t] = [:]
    private var menuDiscovery: [Messenger: Date] = [:]
    private var menuMemory = MenuCounterMemory()
    private var dockPid: pid_t = 0
    private var lastDiscovery = Date.distantPast
    func reset() { dockItems.removeAll(); statusSupported.removeAll(); lastDiscovery = .distantPast; menuItems.removeAll(); menuPids.removeAll(); menuDiscovery.removeAll(); menuMemory.reset() }
    func poll() -> FastMessagePacket {
        let start = Date()
        var packet = FastMessagePacket(); packet.trusted = AXIsProcessTrusted()
        let running = NSWorkspace.shared.runningApplications
        for i in packet.sources.indices {
            let source = packet.sources[i].messenger
            packet.sources[i].running = running.contains { messengerForApplication($0) == source }
            packet.sources[i].status = packet.trusted ? (packet.sources[i].running ? "快速监听中，等待软件提供计数" : "未运行") : "待辅助功能授权，无法监听消息"
        }
        guard packet.trusted else { reset(); return packet }
        if let dock = running.first(where: { $0.bundleIdentifier == "com.apple.dock" }) {
            if dockPid != dock.processIdentifier || start.timeIntervalSince(lastDiscovery) > 20 || (dockItems.isEmpty && start.timeIntervalSince(lastDiscovery) > 3) {
                dockPid = dock.processIdentifier; lastDiscovery = start
                var budget = 100
                let deadline = start.addingTimeInterval(0.16)
                func discover(_ e: AXUIElement, _ depth: Int) {
                    guard depth < 5, budget > 0, Date() < deadline else { return }; budget -= 1
                    if let source = dockMessenger(e) { dockItems[source] = e; return }
                    for c in fastChildren(e) { discover(c, depth + 1) }
                }
                discover(AXUIElementCreateApplication(dock.processIdentifier), 0)
            }
            for i in packet.sources.indices {
                let source = packet.sources[i].messenger
                guard let element = dockItems[source] else { continue }
                let (error, value) = fastValue(element, "AXStatusLabel")
                if error == .invalidUIElement { dockItems.removeValue(forKey: source); lastDiscovery = .distantPast; continue }
                if error == .success, let raw = value as? String {
                    statusSupported.insert(source); packet.sources[i].badgeReadable = true
                    if let (n, lowerBound) = numericDockBadge(raw) {
                        packet.sources[i].unread = n; packet.sources[i].atLeast = lowerBound; packet.sources[i].countOrigin = "Dock 未读角标"
                    } else if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        packet.sources[i].unread = 0; packet.sources[i].countOrigin = "Dock 角标已清空"
                    } else { packet.sources[i].redDot = true; packet.sources[i].status = "有未读标记，软件未提供数字" }
                } else if error == .success, let number = value as? NSNumber, number.intValue >= 0, number.doubleValue == Double(number.intValue) {
                    statusSupported.insert(source); packet.sources[i].badgeReadable = true
                    packet.sources[i].unread = number.intValue; packet.sources[i].countOrigin = "Dock 未读角标"
                } else if error == .noValue && statusSupported.contains(source) && !fastString(element, kAXRoleAttribute).isEmpty {
                    packet.sources[i].badgeReadable = true
                    packet.sources[i].unread = 0; packet.sources[i].countOrigin = "Dock 角标已清空"
                } else if error == .noValue {
                    packet.sources[i].status = "系统无可读数字角标，软件总未读数未知"
                }
            }
        }
        // The user's visible WeChat unread number lives in AXExtrasMenuBar -> AXMenuExtra -> AXTitle.
        // Read it before notifications; no screenshot, no menu click and no chat activation are required.
        for i in packet.sources.indices {
            let source = packet.sources[i].messenger
            guard let application = running.first(where: { messengerForApplication($0) == source }) else { continue }
            if menuPids[source] != application.processIdentifier || start.timeIntervalSince(menuDiscovery[source] ?? .distantPast) > 20 {
                if menuPids[source] != application.processIdentifier { menuMemory.reset(source) }
                menuPids[source] = application.processIdentifier; menuDiscovery[source] = start
                menuItems[source] = messengerExtras(application).1
            }
            let items = menuItems[source] ?? []
            var reading: MenuUnreadReading?
            for item in items {
                let (error, value) = fastValue(item, kAXTitleAttribute)
                if error == .invalidUIElement { menuDiscovery[source] = .distantPast; continue }
                let title = value as? String ?? ""
                if let candidate = menuMemory.update(source, title: title, valid: error == .success || error == .noValue, at: start) {
                    reading = candidate
                    if candidate.count != nil || candidate.redDot { break }
                }
            }
            if let reading {
                packet.sources[i].unread = reading.count; packet.sources[i].atLeast = reading.atLeast
                packet.sources[i].redDot = reading.redDot; packet.sources[i].badgeReadable = reading.confirmed
                packet.sources[i].countOrigin = reading.origin
                packet.sources[i].status = reading.confirmed ? "顶部菜单栏消息计数已接通" : "短暂空白防闪烁确认中"
            }
        }
        if let center = running.first(where: { $0.bundleIdentifier == "com.apple.notificationcenterui" }) {
            let deadline = Date().addingTimeInterval(0.24)
            var budget = 110
            func read(_ e: AXUIElement, _ depth: Int) -> NotificationBranch? {
                guard depth < 12, budget > 0, Date() < deadline else { return nil }; budget -= 1
                let role = fastString(e, kAXRoleAttribute)
                guard role != kAXMenuBarRole && role != kAXMenuRole else { return nil }
                let texts = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { key -> String? in
                    guard Date() < deadline else { return nil }
                    let t = fastString(e, key); return !t.isEmpty && t.count < 1400 ? t : nil
                }
                let identifier = fastString(e, kAXIdentifierAttribute)
                let nodes = fastChildren(e).compactMap { read($0, depth + 1) }
                return NotificationBranch(role: role, texts: Array(NSOrderedSet(array: texts).array as? [String] ?? []), identifier: identifier, children: nodes)
            }
            func extract(_ node: NotificationBranch) -> [Notice] {
                let deeper = node.children.flatMap { extract($0) }
                if !deeper.isEmpty { return deeper }
                guard ![kAXApplicationRole, kAXStaticTextRole, kAXButtonRole, kAXImageRole].contains(node.role) else { return [] }
                let texts = Array(NSOrderedSet(array: node.allText).array as? [String] ?? [])
                let headers = Set(texts.compactMap(headerSource))
                guard headers.count == 1, let source = headers.first else { return [] }
                let body = texts.filter { text in
                    headerSource(text) == nil && !["关闭", "清除", "显示更多", "更多", "Close", "Clear", "现在", "now"].contains(text) && text.range(of: #"^\d+\s*(秒钟?|分钟?|小时|seconds?|minutes?|hours?)前?$"#, options: .regularExpression) == nil
                }.joined(separator: " · ")
                return [Notice(source: source, content: body.isEmpty ? "通知预览未提供" : String(body.prefix(600)), identifier: node.identifier)]
            }
            if let root = read(AXUIElementCreateApplication(center.processIdentifier), 0) { packet.notices = extract(root) }
        }
        packet.completed = Date(); packet.milliseconds = Int(packet.completed.timeIntervalSince(start) * 1000)
        return packet
    }
}

// Observe supported AX signals on a utility run loop, not on the animated UI thread.
final class MessageEventBridge {
    private let ready = DispatchSemaphore(value: 0)
    private var runLoop: CFRunLoop?
    private var observers: [AXObserver] = []
    private var tokens: [EventToken] = []
    private var registrations = 0
    private let signal: () -> Void
    private let stateLock = NSLock()
    private var active = false
    var subscriptionReport: ((Int) -> Void)?
    private final class EventToken {
        weak var owner: MessageEventBridge?
        init(_ owner: MessageEventBridge) { self.owner = owner }
    }
    init(signal: @escaping () -> Void) {
        self.signal = signal
    }
    private var workerStarted = false
    private var workerThread: Thread?
    func start() {
        guard !workerStarted else { return }; workerStarted = true
        let worker = Thread { [weak self] in
            guard let self else { return }
            self.runLoop = CFRunLoopGetCurrent()
            _ = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in }
            self.ready.signal()
            while !Thread.current.isCancelled { autoreleasepool { _ = CFRunLoopRunInMode(.defaultMode, 0.4, false) } }
        }
        worker.name = "DynaPet-message-events"; worker.qualityOfService = .utility; workerThread = worker; worker.start()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }; self.ready.wait(); self.rebuild()
        }
    }
    private func perform(_ work: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, work)
        CFRunLoopWakeUp(runLoop)
    }
    func rebuild() { perform { [weak self] in self?.install() } }
    private func clear() {
        for observer in observers { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observers.removeAll(); tokens.removeAll(); registrations = 0
    }
    private func install() {
        clear()
        stateLock.lock(); let enabled = active; stateLock.unlock()
        guard enabled && AXIsProcessTrusted() else { DispatchQueue.main.async { [weak self] in self?.subscriptionReport?(0) }; return }
        let applications = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.apple.dock" || $0.bundleIdentifier == "com.apple.notificationcenterui" || messengerForApplication($0) != nil }
        for app in applications {
            var observer: AXObserver?
            let result = AXObserverCreate(app.processIdentifier, { _, _, _, context in
                guard let context else { return }
                let token = Unmanaged<EventToken>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async { token.owner?.signal() }
            }, &observer)
            guard result == .success, let observer else { continue }
            let token = EventToken(self); tokens.append(token); observers.append(observer)
            let context = Unmanaged.passUnretained(token).toOpaque()
            let application = AXUIElementCreateApplication(app.processIdentifier)
            func watch(_ element: AXUIElement, _ events: [String]) {
                AXUIElementSetMessagingTimeout(element, 0.04)
                for event in events {
                    if AXObserverAddNotification(observer, element, event as CFString, context) == .success { registrations += 1 }
                }
            }
            let signals = [kAXCreatedNotification, kAXWindowCreatedNotification, kAXLayoutChangedNotification, kAXValueChangedNotification, kAXTitleChangedNotification, kAXAnnouncementRequestedNotification]
            watch(application, signals)
            if app.bundleIdentifier == "com.apple.dock" {
                var budget = 100; let deadline = Date().addingTimeInterval(0.5)
                func dock(_ element: AXUIElement, _ depth: Int) {
                    guard depth < 5, budget > 0, Date() < deadline else { return }; budget -= 1
                    if dockMessenger(element) != nil { watch(element, [kAXValueChangedNotification, kAXTitleChangedNotification, kAXUIElementDestroyedNotification]); return }
                    for c in fastChildren(element) { dock(c, depth + 1) }
                }; dock(application, 0)
            } else {
                for element in fastValue(application, kAXWindowsAttribute).1 as? [AXUIElement] ?? [] { watch(element, signals) }
                if messengerForApplication(app) != nil {
                    let (bar, items) = messengerExtras(app)
                    if let bar { watch(bar, [kAXCreatedNotification, kAXLayoutChangedNotification]) }
                    for item in items { watch(item, [kAXTitleChangedNotification, kAXValueChangedNotification, kAXUIElementDestroyedNotification]) }
                }
            }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        let count = registrations
        DispatchQueue.main.async { [weak self] in self?.subscriptionReport?(count) }
    }
    func setActive(_ active: Bool) {
        stateLock.lock(); self.active = active; stateLock.unlock()
        if active { start(); rebuild() }
        else { perform { [weak self] in self?.clear() } }
    }
    deinit { workerThread?.cancel(); if let runLoop { CFRunLoopStop(runLoop) } }
}

func realtimeMessageSelfTest() {
    func packet(_ counts: [Messenger: Int?] = [:], notices: [Notice] = [], trusted: Bool = true) -> FastMessagePacket {
        var p = FastMessagePacket(); p.trusted = trusted; p.notices = notices
        for i in p.sources.indices { p.sources[i].running = true; p.sources[i].unread = counts[p.sources[i].messenger] ?? nil }
        return p
    }
    var ledger = MessageArrivalLedger(); let base = Date(timeIntervalSince1970: 100)
    precondition(ledger.ingest(packet([.wechat: 3]), now: base).isEmpty)
    let first = ledger.ingest(packet([.wechat: 4]), now: base.addingTimeInterval(1))
    precondition(first.count == 1 && first[0].source == .wechat)
    precondition(ledger.ingest(packet([.wechat: 4], notices: [Notice(source: .wechat, content: "hello", identifier: "n1")]), now: base.addingTimeInterval(1.1)).isEmpty)
    precondition(ledger.ingest(packet([.wechat: 0]), now: base.addingTimeInterval(3)).isEmpty)
    precondition(ledger.ingest(packet([.wechat: 1]), now: base.addingTimeInterval(4)).first?.source == .wechat)
    let ding = Notice(source: .ding, content: "预览已隐藏", identifier: "n2")
    precondition(ledger.ingest(packet(notices: [ding]), now: base.addingTimeInterval(6)).first?.source == .ding)
    precondition(ledger.ingest(packet(notices: [ding]), now: base.addingTimeInterval(8)).isEmpty)
    let qq = Notice(source: .qq, content: "same", identifier: "q1")
    let qq2 = Notice(source: .qq, content: "same", identifier: "q2")
    precondition(ledger.ingest(packet(notices: [qq]), now: base.addingTimeInterval(10)).first?.source == .qq)
    precondition(ledger.ingest(packet(notices: [qq2]), now: base.addingTimeInterval(12)).first?.source == .qq)
    precondition(ledger.ingest(packet([.wechat: 99], trusted: false), now: base.addingTimeInterval(14)).isEmpty)
    precondition(ledger.ingest(packet([.wechat: 99]), now: base.addingTimeInterval(15)).isEmpty)
    var parallel = MessageArrivalLedger()
    _ = parallel.ingest(packet([.wechat: 0, .ding: 0, .qq: 0]), now: base)
    let multiple = parallel.ingest(packet([.wechat: 1, .ding: 2, .qq: 3]), now: base.addingTimeInterval(1))
    precondition(Set(multiple.map(\.source)) == Set(Messenger.allCases))
    precondition(parallel.ingest(packet(), now: base.addingTimeInterval(3)).isEmpty)
    precondition(parallel.ingest(packet([.wechat: 1, .ding: 2, .qq: 3]), now: base.addingTimeInterval(5)).isEmpty)
    precondition(classifyMessengerDockItem(subrole: "AXApplicationDockItem", title: "微信", urlName: "WeChat.app") == .wechat)
    precondition(classifyMessengerDockItem(subrole: "AXMinimizedWindowDockItem", title: "微信", urlName: "") == nil)
    precondition(classifyMessengerDockItem(subrole: "AXFolderDockItem", title: "微信", urlName: "") == nil)
    precondition(numericDockBadge("1 item")?.0 == 1 && numericDockBadge("3 条新消息")?.0 == 3)
    var dots = MessageArrivalLedger()
    _ = dots.ingest(packet(), now: base)
    var red = packet(); red.sources[0].redDot = true; red.sources[0].badgeReadable = true
    precondition(dots.ingest(red, now: base.addingTimeInterval(1)).first?.source == .wechat)
    precondition(dots.ingest(red, now: base.addingTimeInterval(3)).isEmpty)
    _ = dots.ingest(packet(), now: base.addingTimeInterval(4))
    precondition(dots.ingest(red, now: base.addingTimeInterval(5)).isEmpty)
    var noDot = packet(); noDot.sources[0].badgeReadable = true
    _ = dots.ingest(noDot, now: base.addingTimeInterval(6))
    precondition(dots.ingest(red, now: base.addingTimeInterval(7)).first?.source == .wechat)
    var identity = MessageArrivalLedger()
    _ = identity.ingest(packet(), now: base)
    _ = identity.ingest(packet(notices: [Notice(source: .wechat, content: "预览暂未提供", identifier: "stable")]), now: base.addingTimeInterval(1))
    precondition(identity.ingest(packet(notices: [Notice(source: .wechat, content: "正文稍后出现", identifier: "stable")]), now: base.addingTimeInterval(3)).isEmpty)
    var menu = MenuCounterMemory()
    precondition(menu.update(.wechat, title: " 5", valid: true, at: base)?.count == 5)
    precondition(menu.update(.wechat, title: "", valid: true, at: base.addingTimeInterval(0.5))?.count == 5)
    precondition(menu.update(.wechat, title: " 5", valid: true, at: base.addingTimeInterval(1))?.count == 5)
    _ = menu.update(.wechat, title: "", valid: true, at: base.addingTimeInterval(2))
    precondition(menu.update(.wechat, title: "", valid: true, at: base.addingTimeInterval(4.1))?.count == 0)
    precondition(menu.update(.wechat, title: " 6", valid: true, at: base.addingTimeInterval(5))?.count == 6)
    precondition(menu.update(.wechat, title: "", valid: false, at: base.addingTimeInterval(6)) == nil)
    var menuLedger = MessageArrivalLedger()
    var five = packet([.wechat: 5]); five.sources[0].countOrigin = "顶部菜单栏计数"
    _ = menuLedger.ingest(five, now: base)
    var six = five; six.sources[0].unread = 6
    precondition(menuLedger.ingest(six, now: base.addingTimeInterval(1)).first?.source == .wechat)
    var blink = six; blink.sources[0].countOrigin = "顶部菜单栏计数（防闪烁确认）"
    precondition(menuLedger.ingest(blink, now: base.addingTimeInterval(3)).isEmpty)
    precondition(headerSource("QQ音乐") == nil && headerSource("QQ") == .qq && headerSource("微信\n张三") == .wechat)
    print("PASS: real-time arrival ledger: baseline, badge increase, read-clear, deduplication, hidden preview, repeated content, permission reset, correct Dock item, red dots, stable notification identity, live menu counter and anti-blink debounce")
}

extension RealtimeMessengerMonitor {
    func inspectDockCapabilities() -> [[String: Any]] {
        guard AXIsProcessTrusted(), let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [["error": "辅助功能未授权或 Dock 未运行"]] }
        var result: [[String: Any]] = [], budget = 180
        let deadline = Date().addingTimeInterval(3)
        func inspect(_ element: AXUIElement, _ depth: Int) {
            guard depth < 7, budget > 0, Date() < deadline else { return }; budget -= 1
            let role = fastString(element, kAXRoleAttribute), subrole = fastString(element, kAXSubroleAttribute)
            let title = fastString(element, kAXTitleAttribute), description = fastString(element, kAXDescriptionAttribute)
            let url = (fastValue(element, kAXURLAttribute).1 as? URL)?.lastPathComponent ?? ""
            let matching = Messenger.allCases.first { $0.matches(name: title + " " + description + " " + url) }
            let children = fastChildren(element)
            if matching != nil || depth < 2 {
                var attributes: CFArray?
                AXUIElementCopyAttributeNames(element, &attributes)
                let (error, value) = fastValue(element, "AXStatusLabel")
                result.append(["depth": depth, "role": role, "subrole": subrole, "title": matching != nil ? title : "（结构节点）", "description": matching != nil ? description : "", "source": matching?.rawValue as Any? ?? NSNull(), "urlName": matching != nil ? url : "", "selectedByReader": dockMessenger(element) != nil, "statusError": error.rawValue, "statusType": value.map { String(describing: type(of: $0)) } ?? "nil", "statusValue": value.map { String(describing: $0) } ?? "nil", "attributes": attributes as? [String] ?? [], "children": children.count])
            }
            for c in children { inspect(c, depth + 1) }
        }
        inspect(AXUIElementCreateApplication(dock.processIdentifier), 0)
        return result
    }
}

extension RealtimeMessengerMonitor {
    func inspectStatusMenuCapabilities() -> [[String: Any]] {
        var rows: [[String: Any]] = []
        guard AXIsProcessTrusted() else { return [["kind": "status-menu", "error": "待辅助功能授权"]] }
        let apps = NSWorkspace.shared.runningApplications.filter { messengerForApplication($0) != nil }
        for app in apps {
            guard let source = messengerForApplication(app) else { continue }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            var rootAttributes: CFArray?; AXUIElementCopyAttributeNames(root, &rootAttributes)
            rows.append(["kind": "status-menu-root", "source": source.rawValue, "attributes": rootAttributes as? [String] ?? []])
            var bars: [(String, AXUIElement)] = []
            let (error, raw) = fastValue(root, "AXExtrasMenuBar")
            if let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() { bars.append(("AXExtrasMenuBar", raw as! AXUIElement)) }
            rows.append(["kind": "status-menu-lookup", "source": source.rawValue, "error": error.rawValue, "valueType": raw.map { String(describing: type(of: $0)) } ?? "nil"])
            for (index, child) in fastChildren(root).enumerated() where fastString(child, kAXRoleAttribute) == kAXMenuBarRole {
                if !bars.contains(where: { CFEqual($0.1, child) }) { bars.append(("AXChildren[\(index)]", child)) }
            }
            var budget = 60
            func inspect(_ element: AXUIElement, _ depth: Int, _ origin: String) {
                guard depth < 3, budget > 0 else { return }; budget -= 1
                let children = fastChildren(element)
                var fields: [String: Any] = ["kind": "status-menu", "source": source.rawValue, "depth": depth, "origin": origin, "children": children.count]
                for key in [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute, "AXStatusLabel"] {
                    let (error, value) = fastValue(element, key)
                    fields[key] = value.map { String(String(describing: $0).prefix(100)) } ?? "nil"
                    if key == kAXValueAttribute || key == "AXStatusLabel" { fields[key + "Error"] = error.rawValue }
                }
                var names: CFArray?; AXUIElementCopyAttributeNames(element, &names); fields["attributes"] = names as? [String] ?? []
                rows.append(fields)
                for child in children { inspect(child, depth + 1, origin) }
            }
            for (origin, bar) in bars { inspect(bar, 0, origin) }
        }
        return rows
    }
}
