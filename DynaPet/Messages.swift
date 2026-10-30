import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision
import CryptoKit

// Every number carries its provenance. A missing badge is NOT silently treated as zero.
enum Messenger: String, CaseIterable, Identifiable, Hashable {
    case wechat = "微信", ding = "钉钉", qq = "QQ"
    var id: String { rawValue }
    var bundle: String { switch self { case .wechat: return "com.tencent.xinWeChat"; case .ding: return "5ZSL2CJU2T.com.dingtalk.mac"; case .qq: return "com.tencent.qq" } }
    func matches(name: String) -> Bool {
        let s = name.lowercased()
        switch self {
        case .wechat: return s.contains("微信") || s.contains("wechat") || s.contains("xinwechat")
        case .ding: return s.contains("钉钉") || s.contains("dingtalk")
        case .qq: return s == "qq" || s.contains("com.tencent.qq") || s.hasPrefix("qq.app") || s.hasPrefix("qq ") || s.hasPrefix("qq（") || s.hasPrefix("qq(")
        }
    }
}
struct InboxSource: Identifiable {
    var messenger: Messenger
    var id: String { messenger.id }
    var running = false, unread: Int? = nil, atLeast = false, redDot = false
    var countOrigin = "软件未提供", preview = "", previewOrigin = "", status = "等待扫描"
    var ocrStatus = ""
    var observedNotifications = 0, visibleMarkedMessages: Int? = nil
    var lastAlertAt: Date? = nil, alertOrigin = ""
    var badgeReadable = false
    var unreadLabel: String { if let n = unread { return "未读计数 \(n)\(atLeast ? "+" : "")（\(countOrigin)）" }; return redDot ? "有未读标记，条数未知" : "未读数未提供" }
}
struct Notice: Hashable {
    var source: Messenger, content: String
    var identifier = ""
    var signature: String { SHA256.hash(data: Data((source.rawValue + "|" + (identifier.isEmpty ? content : identifier)).utf8)).map { String(format: "%02x", $0) }.joined() }
}
struct MessageScan { var sources = Messenger.allCases.map { InboxSource(messenger: $0) }; var arrivals: [Notice] = [] }
struct AXNode {
    var role: String, texts: [String], children: [AXNode]
    var allText: [String] { texts + children.flatMap(\.allText) }
    var readableText: [String] { (role == kAXStaticTextRole || role == kAXRowRole ? texts : []) + children.flatMap(\.readableText) }
}
func exactBadge(_ raw: String) -> (Int, Bool)? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard s.range(of: #"^\d{1,6}\+?$"#, options: .regularExpression) != nil, let n = Int(s.filter(\.isNumber)) else { return nil }
    return (n, s.hasSuffix("+"))
}
func explicitUnread(_ text: String) -> Int? {
    let patterns = [#"(?:未读消息|未读)[：: \t（(]*(\d{1,6})"#, #"(\d{1,6})\s*条未读(?:消息)?"#, #"(\d{1,6})\s+unread messages"#]
    for p in patterns {
        guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]), let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(m.range(at: 1), in: text) else { continue }
        if let n = Int(text[r]) { return n }
    }
    return nil
}
actor MessengerMonitor {
    private var epoch = 0
    private var seen = Set<String>(), order: [String] = [], initialized = false
    private var counters: [Messenger: Int] = [:]
    private var cachedPreviews: [Messenger: (String, String, Date)] = [:]
    func reset() { epoch += 1; seen.removeAll(); order.removeAll(); counters.removeAll(); cachedPreviews.removeAll(); initialized = false }
    func tree(_ e: AXUIElement, depth: Int, budget: inout Int, deadline: Date) -> AXNode? {
        guard depth < 13, budget > 0, Date() < deadline else { return nil }; budget -= 1
        let role = axValue(e, kAXRoleAttribute) as? String ?? ""
        guard role != kAXMenuBarRole && role != kAXMenuRole else { return nil }
        let texts = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { axValue(e, $0) as? String }.filter { !$0.isEmpty && $0.count < 1400 }
        var children: [AXNode] = []
        for c in axChildren(e) { if let n = tree(c, depth: depth + 1, budget: &budget, deadline: deadline) { children.append(n) } }
        return AXNode(role: role, texts: Array(NSOrderedSet(array: texts).array as? [String] ?? []), children: children)
    }
    func notices(_ node: AXNode) -> [Notice] {
        let inner = node.children.flatMap { notices($0) }
        if !inner.isEmpty { return inner }
        guard node.role != kAXStaticTextRole && node.role != kAXButtonRole else { return [] }
        let text = Array(NSOrderedSet(array: node.allText).array as? [String] ?? [])
        let matches = Messenger.allCases.filter { m in text.contains { t in m.matches(name: t) } }
        guard matches.count == 1, let source = matches.first else { return [] }
        let body = text.filter { t in
            ![source.rawValue, "关闭", "清除", "更多", "Close", "Clear", "现在", "now"].contains(t) && t.range(of: #"^\d+\s*(秒钟?|分钟?|小时|seconds?|minutes?|hours?)前?$"#, options: .regularExpression) == nil
        }.joined(separator: " · ")
        guard body.count > source.rawValue.count + 3 else { return [] }
        return [Notice(source: source, content: String(body.prefix(600)))]
    }
    func scan(useOCR: Bool) async -> MessageScan {
        let token = epoch
        var result = MessageScan()
        let apps = NSWorkspace.shared.runningApplications
        let ax = AXIsProcessTrusted()
        var badgeValues: [Messenger: (Int, Bool)] = [:], dots = Set<Messenger>()
        if ax, let dock = apps.first(where: { $0.bundleIdentifier == "com.apple.dock" }) {
            var budget = 220
            let deadline = Date().addingTimeInterval(1.3)
            func inspect(_ e: AXUIElement, _ depth: Int) {
                guard depth < 6, budget > 0, Date() < deadline else { return }; budget -= 1
                let label = (axValue(e, kAXTitleAttribute) as? String ?? "") + " " + ((axValue(e, kAXURLAttribute) as? URL)?.lastPathComponent ?? "")
                for m in Messenger.allCases where m.matches(name: label.trimmingCharacters(in: .whitespaces)) {
                    if let badge = axValue(e, "AXStatusLabel") as? String {
                        if let parsed = exactBadge(badge) { badgeValues[m] = parsed }
                        else if !badge.isEmpty { dots.insert(m) }
                    }
                }
                for c in axChildren(e) { inspect(c, depth + 1) }
            }
            inspect(appElement(dock), 0)
        }
        var noticesNow: [Notice] = []
        if ax, let center = apps.first(where: { $0.bundleIdentifier == "com.apple.notificationcenterui" }) {
            var budget = 220
            if let n = tree(appElement(center), depth: 0, budget: &budget, deadline: Date().addingTimeInterval(1.5)) { noticesNow = notices(n) }
        }
        var arrivals: [Notice] = []
        for notice in noticesNow where !seen.contains(notice.signature) {
            seen.insert(notice.signature); order.append(notice.signature)
            if initialized { arrivals.append(notice); counters[notice.source, default: 0] += 1 }
            cachedPreviews[notice.source] = (notice.content, "系统通知", Date())
        }
        initialized = true
        if order.count > 500 { for id in order.prefix(order.count - 500) { seen.remove(id) }; order = Array(order.suffix(500)) }
        for i in result.sources.indices {
            let m = result.sources[i].messenger
            let app = apps.first { $0.bundleIdentifier?.lowercased() == m.bundle.lowercased() || ($0.bundleIdentifier?.lowercased().contains("dingtalk") == true && m == .ding) }
            result.sources[i].running = app != nil
            result.sources[i].status = app == nil ? "未运行" : "等待软件提供未读数"
            result.sources[i].observedNotifications = counters[m, default: 0]
            result.sources[i].redDot = dots.contains(m)
            if let b = badgeValues[m] { result.sources[i].unread = b.0; result.sources[i].atLeast = b.1; result.sources[i].countOrigin = "Dock 角标" }
            if let app, ax {
                var budget = 170
                let windows = axChildren(appElement(app), kAXWindowsAttribute)
                var texts: [String] = []
                let deadline = Date().addingTimeInterval(0.9)
                for w in windows { if let node = tree(w, depth: 0, budget: &budget, deadline: deadline) { texts += node.readableText } }
                let clean = Array(NSOrderedSet(array: texts).array as? [String] ?? []).filter { !$0.unicodeScalars.contains(where: { (0xE000...0xF8FF).contains(Int($0.value)) }) }
                if m == .ding {
                    let marked = clean.compactMap { t -> Int? in
                        guard let re = try? NSRegularExpression(pattern: #"^\[(\d+)\s*条\]"#), let match = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let range = Range(match.range(at: 1), in: t) else { return nil }
                        return Int(t[range])
                    }
                    if !marked.isEmpty { result.sources[i].visibleMarkedMessages = marked.reduce(0, +) }
                }
                if result.sources[i].unread == nil, let n = explicitUnread(clean.joined(separator: "\n")) { result.sources[i].unread = n; result.sources[i].countOrigin = "软件未读标签" }
                if clean.filter({ $0.count > 3 }).count > 5 {
                    cachedPreviews[m] = (String(clean.suffix(10).joined(separator: " · ").prefix(600)), "软件可访问文字（不保证全量）", Date())
                    result.sources[i].status = "可读软件文字"
                } else { result.sources[i].status = "软件未开放正文接口" }
            }
            if let cache = cachedPreviews[m], Date().timeIntervalSince(cache.2) < 300 { result.sources[i].preview = cache.0; result.sources[i].previewOrigin = cache.1 }
        }
        if useOCR && CGPreflightScreenCaptureAccess() {
            await captureWindows(into: &result, token: token)
        } else if useOCR {
            for i in result.sources.indices where result.sources[i].running { result.sources[i].ocrStatus = "OCR：待屏幕录制授权" }
        }
        result.arrivals = arrivals
        return result
    }
    private func captureWindows(into result: inout MessageScan, token: Int) async {
        do {
            let share = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard epoch == token else { return }
            for i in result.sources.indices where result.sources[i].running {
                let m = result.sources[i].messenger
                let candidates = share.windows.filter { w in w.isOnScreen && w.windowLayer == 0 && w.frame.width > 320 && w.frame.height > 250 && (w.owningApplication?.bundleIdentifier.lowercased() == m.bundle.lowercased() || (m == .ding && w.owningApplication?.bundleIdentifier.lowercased().contains("dingtalk") == true)) }
                guard let w = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { result.sources[i].ocrStatus = "OCR：无可捕获窗口，请将软件窗口显示在当前桌面"; continue }
                do {
                    let filter = SCContentFilter(desktopIndependentWindow: w)
                    let config = SCStreamConfiguration(); config.width = min(1500, Int(w.frame.width * 1.5)); config.height = Int(Double(config.width) * w.frame.height / w.frame.width)
                    config.showsCursor = false; config.captureResolution = .best; config.ignoreShadowsSingleWindow = true
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    guard epoch == token else { return }
                    let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans", "en-US"]; request.usesLanguageCorrection = false
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                    let rows = (request.results ?? []).sorted { a, b in if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.018 { return a.boundingBox.midY > b.boundingBox.midY }; return a.boundingBox.minX < b.boundingBox.minX }
                    let lines = rows.compactMap { $0.topCandidates(1).first?.string }
                    let text = lines.joined(separator: "\n")
                    result.sources[i].ocrStatus = text.isEmpty ? "OCR：识别完成，未检测到文字" : "OCR：窗口文字已识别"
                    if ["扫码登录", "手机扫码", "正在登录", "登录QQ", "账号登录"].contains(where: { text.contains($0) }) { result.sources[i].status = "软件处于登录界面"; continue }
                    if !text.isEmpty {
                        // Prefer the last visible messages; never click a conversation or mark it read.
                        let preview = String(lines.suffix(14).joined(separator: " · ").prefix(600))
                        cachedPreviews[m] = (preview, "窗口 OCR（可见文字）", Date())
                        result.sources[i].preview = preview; result.sources[i].previewOrigin = "窗口 OCR（可见文字）"; result.sources[i].status = "窗口文字已识别"
                        if result.sources[i].unread == nil, let n = explicitUnread(text) { result.sources[i].unread = n; result.sources[i].countOrigin = "窗口未读标签 OCR" }
                    }
                } catch {
                    guard epoch == token else { return }
                    let failure = error as NSError
                    result.sources[i].ocrStatus = "OCR：窗口捕获或识别失败（\(failure.domain) / \(failure.code)），请检查屏幕录制授权和窗口状态"
                }
            }
        } catch {
            guard epoch == token else { return }
            let failure = error as NSError
            for i in result.sources.indices where result.sources[i].running {
                result.sources[i].ocrStatus = "OCR：无法获取窗口列表（\(failure.domain) / \(failure.code)），请检查屏幕录制权限"
            }
        }
    }
}
private extension Optional where Wrapped == String { var orEmpty: String { self ?? "" } }

func messageSelfTest() {
    precondition(exactBadge("99+")?.0 == 99 && exactBadge("99+")?.1 == true)
    precondition(exactBadge("3")?.0 == 3)
    precondition(exactBadge("下午 12:30") == nil)
    precondition(exactBadge("[6条] 李明发来文件") == nil)
    precondition(explicitUnread("未读消息：12") == 12)
    precondition(explicitUnread("3 条未读消息") == 3)
    precondition(explicitUnread("消息内容有2026年10月28日") == nil)
    precondition(Messenger.wechat.matches(name: "微信 WeChat.app"))
    precondition(Messenger.ding.matches(name: "DingTalk.app"))
    precondition(!Messenger.qq.matches(name: "QQ音乐"))
    precondition(InboxSource(messenger: .wechat).unread == nil)
    print("PASS: source recognition, capped badge counts, explicit unread parsing, unknown count semantics")
}
