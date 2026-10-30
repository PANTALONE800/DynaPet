import AppKit
import ImageIO
import Dispatch
import IPCProtocol
import PetCore

public struct MacWindowSnapshot: Codable {
    public let visible: Bool
    public let borderless: Bool
    public let transparent: Bool
    public let level: Int
    public let floatingLevel: Int
    public let clickThrough: Bool
    public let width: Double
    public let height: Double
    public let x: Double
    public let y: Double
    public let animation: String
    public let animationFrame: Int
    public let frameChanges: Int
    public let animationStarts: Int
    public let windowNumber: Int
    public let appliedOnMainThread: Bool
}

private final class PetCanvas: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    var image: NSImage? { didSet { needsDisplay = true } }
    var caption = "右键可查看状态与操作" { didSet { needsDisplay = true } }
    override func rightMouseDown(with event: NSEvent) {
        guard let menu else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); dirtyRect.fill(using: .copy)
        if let image {
            let available = bounds.insetBy(dx: 12, dy: 24)
            let ratio = min(available.width / image.size.width, available.height / image.size.height)
            let size = NSSize(width: image.size.width * ratio, height: image.size.height * ratio)
            let target = NSRect(x: bounds.midX - size.width / 2, y: available.minY, width: size.width, height: size.height)
            image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
        let textBox = NSRect(x: 4, y: 3, width: bounds.width - 8, height: 18)
        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: textBox, xRadius: 9, yRadius: 9).fill()
        (caption as NSString).draw(in: textBox, withAttributes: attributes)
    }
}
private final class PetWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

public final class MacPetWindowAdapter: PetWindowHandling {
    public static let baseWidth = 240.0
    public static let baseHeight = 260.0
    private let assets: URL
    private var window: NSWindow?
    private var canvas: PetCanvas?
    private var contextMenu: NSMenu?
    private var statusPanel: NSPanel?
    private var statusText: NSTextField?
    private var statusTimer: Timer?
    private var frames: [String: [NSImage]] = [:]
    private var timer: Timer?
    private var animation = "idle"
    private var animationFrame = 0
    private var frameChanges = 0
    private var animationStarts = 0
    private var closed = false
    private var lastAppliedOnMain = true
    public init(assets: URL) { self.assets = assets }

    public func setContextMenu(_ menu: NSMenu) {
        precondition(Thread.isMainThread)
        contextMenu = menu
        canvas?.menu = menu
    }

    public func toggleStatusPanel() {
        precondition(Thread.isMainThread)
        if let statusPanel, statusPanel.isVisible {
            statusPanel.orderOut(nil)
            statusTimer?.invalidate(); statusTimer = nil
            return
        }
        if statusPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
                                styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "DynaPet · 当前状态"
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.level = .floating
            let text = NSTextField(wrappingLabelWithString: "")
            text.frame = NSRect(x: 16, y: 16, width: 308, height: 164)
            panel.contentView?.addSubview(text)
            panel.center()
            statusPanel = panel; statusText = text
        }
        refreshStatusPanel()
        statusPanel?.orderFrontRegardless()
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self, self.statusPanel?.isVisible == true else { timer.invalidate(); return }
            self.refreshStatusPanel()
        }
    }

    private func refreshStatusPanel() {
        let frame = window?.frame ?? .zero
        statusText?.stringValue = "桌宠：\(window?.isVisible == true ? "显示" : "隐藏")\n当前动作：\(animation) · 帧 \(animationFrame + 1)\n状态：\(canvas?.caption ?? "准备中")\n窗口：\(Int(frame.width)) × \(Int(frame.height))\n位置：\(Int(frame.minX)), \(Int(frame.minY))（屏幕左下为原点）\n消息感知、OCR、登录启动：尚未迁移"
    }

    /// Every mutation, including calls originating on the main thread, enters
    /// through this asynchronous boundary. Completion runs after the mutation.
    private func onMain(_ completion: @escaping PetWindowCompletion, _ operation: @escaping () throws -> Void) {
        DispatchQueue.main.async { [self] in
            dispatchPrecondition(condition: .onQueue(.main))
            precondition(Thread.isMainThread)
            lastAppliedOnMain = Thread.isMainThread
            do { try operation(); completion(.success(())) }
            catch let error as PetWindowFailure { completion(.failure(error)) }
            catch { completion(.failure(.windowUnavailable)) }
        }
    }
    private func requireWindow() throws -> NSWindow {
        precondition(Thread.isMainThread)
        guard !closed, let window else { throw PetWindowFailure.windowUnavailable }
        return window
    }
    private func loadFrames(_ name: String) throws -> [NSImage] {
        precondition(Thread.isMainThread)
        if let cached = frames[name] { return cached }
        guard Mood(rawValue: name) != nil else { throw PetWindowFailure.unsupportedAnimation }
        let path = assets.appendingPathComponent(name + ".png")
        guard let source = CGImageSourceCreateWithURL(path as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil), sheet.width % 3 == 0 else { throw PetWindowFailure.assetUnavailable }
        let width = sheet.width / 3
        let cells = (0..<3).compactMap { sheet.cropping(to: CGRect(x: $0 * width, y: 0, width: width, height: sheet.height)) }
        guard cells.count == 3 else { throw PetWindowFailure.assetUnavailable }
        // Keep one common crop for all poses to prevent frame-to-frame jumping.
        let boxes = cells.compactMap(Self.alphaBounds)
        guard boxes.count == 3 else { throw PetWindowFailure.assetUnavailable }
        let box = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }.integral
        let images = cells.compactMap { image -> NSImage? in
            guard let cropped = image.cropping(to: box) else { return nil }
            return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
        }
        guard images.count == 3 else { throw PetWindowFailure.assetUnavailable }
        frames[name] = images
        return images
    }
    private static func alphaBounds(_ image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var left = width, right = -1, bottom = height, top = -1
        for y in 0..<height { for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 180 {
            left = min(left, x); right = max(right, x); bottom = min(bottom, y); top = max(top, y)
        } }
        guard right >= left, top >= bottom else { return nil }
        return CGRect(x: left, y: height - top - 1, width: right - left + 1, height: top - bottom + 1)
    }
    public func showWindow(completion: @escaping PetWindowCompletion) {
        onMain(completion) { [self] in
            guard !closed else { throw PetWindowFailure.windowUnavailable }
            if window == nil {
                let idle = try loadFrames("idle")
                for mood in Mood.allCases { _ = try loadFrames(mood.rawValue) }
                let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
                let width = min(Self.baseWidth, area.width)
                let height = min(Self.baseHeight, area.height)
                let x = area.midX - width / 2
                let y = area.minY + min(80, max(0, area.height - height))
                let created = PetWindow(contentRect: NSRect(x: x, y: y, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
                created.title = "DynaPet"
                created.backgroundColor = .clear
                created.isOpaque = false
                created.hasShadow = false
                created.level = .floating
                created.ignoresMouseEvents = false
                created.isReleasedWhenClosed = false
                created.isMovableByWindowBackground = true
                created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                let content = PetCanvas(frame: NSRect(origin: .zero, size: created.frame.size))
                content.autoresizingMask = [.width, .height]; content.image = idle[0]
                created.contentView = content
                content.menu = contextMenu
                canvas = content; window = created
            }
            try requireWindow().orderFrontRegardless()
        }
    }
    /// Hide without destroying the window or interrupting animation state.
    public func hideWindow(completion: @escaping PetWindowCompletion = { _ in }) {
        onMain(completion) { [self] in try requireWindow().orderOut(nil) }
    }
    public func setAlwaysOnTop(_ isOn: Bool, completion: @escaping PetWindowCompletion) {
        onMain(completion) { [self] in try requireWindow().level = isOn ? .floating : .normal }
    }
    public func setClickThrough(_ isOn: Bool, completion: @escaping PetWindowCompletion) {
        onMain(completion) { [self] in try requireWindow().ignoresMouseEvents = isOn }
    }
    public func updatePosition(x: Double, y: Double, completion: @escaping PetWindowCompletion) {
        onMain(completion) { [self] in
            guard x.isFinite, y.isFinite, abs(x) <= 100_000, abs(y) <= 100_000 else { throw PetWindowFailure.invalidArgument }
            let window = try requireWindow()
            let top = NSScreen.screens.map(\.frame.maxY).max() ?? 0
            window.setFrameOrigin(NSPoint(x: x, y: top - y - window.frame.height))
        }
    }
    public func updateSize(scale: Double, completion: @escaping PetWindowCompletion) {
        onMain(completion) { [self] in
            guard scale.isFinite, [0.75, 1.0, 1.25].contains(scale) else { throw PetWindowFailure.invalidArgument }
            let window = try requireWindow()
            var frame = window.frame
            frame.size = NSSize(width: Self.baseWidth * scale, height: Self.baseHeight * scale)
            window.setFrame(frame, display: true)
        }
    }
    public func playAnimation(name: String, completion: @escaping PetWindowCompletion) {
        onMain(completion) { [self] in
            _ = try requireWindow()
            let clip = try loadFrames(name)
            timer?.invalidate(); timer = nil
            animation = name; animationFrame = 0; animationStarts += 1
            canvas?.image = clip[0]
            canvas?.caption = name == "happy" ? "好耶！收到 Electron 的摸摸啦" : "等待 Electron 的摸摸请求"
            guard let mood = Mood(rawValue: name) else { throw PetWindowFailure.unsupportedAnimation }
            let started = Date().timeIntervalSinceReferenceDate
            let actionStart = mood.animationTiming.period - mood.animationTiming.duration
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
                guard let self, !self.closed else { timer.invalidate(); return }
                precondition(Thread.isMainThread)
                let next = mood.animationFrame(at: actionStart + Date().timeIntervalSinceReferenceDate - started)
                if next != self.animationFrame {
                    self.animationFrame = next; self.frameChanges += 1
                    self.canvas?.image = clip[next]
                }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    public func updateStatusText(_ text: String, completion: @escaping PetWindowCompletion) {
        onMain(completion) { [self] in
            _ = try requireWindow()
            guard text.utf8.count <= 2048 else { throw PetWindowFailure.invalidArgument }
            canvas?.caption = text
            canvas?.toolTip = text
        }
    }
    public func closeWindow(completion: @escaping PetWindowCompletion) {
        onMain(completion) { [self] in
            timer?.invalidate(); timer = nil
            statusTimer?.invalidate(); statusTimer = nil
            statusPanel?.close(); statusPanel = nil; statusText = nil
            contextMenu = nil
            window?.orderOut(nil); window?.close(); window = nil; canvas = nil
            frames.removeAll(); closed = true
        }
    }
    /// Adapter-local inspection for integration tests; no native objects cross
    /// into the core protocol or IPC request parameters.
    public func inspect(completion: @escaping (MacWindowSnapshot) -> Void) {
        DispatchQueue.main.async { [self] in
            precondition(Thread.isMainThread)
            let frame = window?.frame ?? .zero
            let top = NSScreen.screens.map(\.frame.maxY).max() ?? 0
            completion(MacWindowSnapshot(visible: window?.isVisible ?? false,
                borderless: window?.styleMask == .borderless,
                transparent: window?.isOpaque == false && window?.backgroundColor?.alphaComponent == 0,
                level: window?.level.rawValue ?? 0, floatingLevel: NSWindow.Level.floating.rawValue,
                clickThrough: window?.ignoresMouseEvents ?? false,
                width: frame.width, height: frame.height, x: frame.minX, y: top - frame.maxY,
                animation: animation, animationFrame: animationFrame, frameChanges: frameChanges,
                animationStarts: animationStarts, windowNumber: window?.windowNumber ?? 0,
                appliedOnMainThread: lastAppliedOnMain))
        }
    }
    public func savePreview(to url: URL, completion: @escaping PetWindowCompletion) {
        onMain(completion) { [self] in
            _ = try requireWindow()
            guard let canvas, let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { throw PetWindowFailure.windowUnavailable }
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PetWindowFailure.windowUnavailable }
            try png.write(to: url, options: .atomic)
        }
    }
}
