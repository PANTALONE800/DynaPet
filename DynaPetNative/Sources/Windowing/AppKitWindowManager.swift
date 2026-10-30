#if canImport(AppKit)
import AppKit
#if canImport(PetCore)
import PetCore
#endif

/// Wraps the existing NSPanel; it does not replace the SwiftUI renderer or menus.
public final class AppKitWindowManager: WindowManager {
    private unowned let window: NSWindow
    public init(window: NSWindow) { self.window = window }
    private var desktopTop: CGFloat { NSScreen.screens.map(\.frame.maxY).max() ?? 0 }
    public var bounds: WindowBounds {
        let frame = window.frame
        return WindowBounds(x: frame.minX, y: desktopTop - frame.maxY, width: frame.width, height: frame.height)
    }
    public func setBounds(_ bounds: WindowBounds) {
        guard bounds.isValid else { return }
        window.setFrame(NSRect(x: bounds.origin.x, y: desktopTop - bounds.origin.y - bounds.height,
                               width: bounds.width, height: bounds.height), display: true)
    }
    public func setAlwaysOnTop(_ enabled: Bool) { window.level = enabled ? .floating : .normal }
    public func setVisible(_ visible: Bool) {
        if visible { window.orderFrontRegardless() } else { window.orderOut(nil) }
    }
}
#endif
