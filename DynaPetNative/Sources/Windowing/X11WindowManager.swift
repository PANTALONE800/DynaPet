#if os(Linux)
import Foundation
import Glibc
import CX11
import PetCore

public enum X11WindowError: Error, CustomStringConvertible {
    case unavailableDisplay, missingAlphaVisual, allocationFailed
    public var description: String {
        switch self {
        case .unavailableDisplay: return "无法连接 X11；请在 Ubuntu on Xorg 会话中启动。"
        case .missingAlphaVisual: return "X11 未提供带透明通道的 32 位视觉格式。"
        case .allocationFailed: return "无法创建 X11 桌宠窗口。"
        }
    }
}
public enum DesktopWindowEvent {
    case redraw
    case buttonDown(button: UInt32, cursor: DesktopPoint)
    case buttonUp(button: UInt32, cursor: DesktopPoint)
    case pointerMoved(cursor: DesktopPoint)
    case geometryChanged
    case close
}

/// All Xlib calls run on the owner thread. The instance owns its display,
/// colormap and window, and releases them in the reverse order of allocation.
public final class X11WindowManager: WindowManager {
    public let display: OpaquePointer
    public let window: Window
    public let visual: UnsafeMutablePointer<Visual>
    private let root: Window
    private let colormap: Colormap
    private let owner = pthread_self()
    private let deleteAtom: Atom
    private var frame: WindowBounds
    private var isVisible = false
    public var onEvent: ((DesktopWindowEvent) -> Void)?
    public var bounds: WindowBounds { frame }
    public var screenSize: (width: Int, height: Int) {
        (Int(XDisplayWidth(display, XDefaultScreen(display))), Int(XDisplayHeight(display, XDefaultScreen(display))))
    }

    public init(bounds: WindowBounds) throws {
        guard bounds.isValid else { throw X11WindowError.allocationFailed }
        guard let display = XOpenDisplay(nil) else { throw X11WindowError.unavailableDisplay }
        let screen = XDefaultScreen(display)
        let root = XRootWindow(display, screen)
        var info = XVisualInfo()
        guard XMatchVisualInfo(display, screen, 32, TrueColor, &info) != 0,
              let visual = info.visual,
              let format = XRenderFindVisualFormat(display, visual), format.pointee.direct.alphaMask != 0 else {
            XCloseDisplay(display); throw X11WindowError.missingAlphaVisual
        }
        let colormap = XCreateColormap(display, root, visual, AllocNone)
        var attributes = XSetWindowAttributes()
        attributes.colormap = colormap
        attributes.border_pixel = 0
        attributes.background_pixel = 0
        attributes.event_mask = ExposureMask | ButtonPressMask | ButtonReleaseMask | PointerMotionMask | StructureNotifyMask
        let window = XCreateWindow(display, root, Int32(bounds.origin.x), Int32(bounds.origin.y),
                                   UInt32(bounds.width), UInt32(bounds.height), 0, 32, UInt32(InputOutput), visual,
                                   UInt(CWColormap | CWBorderPixel | CWBackPixel | CWEventMask), &attributes)
        guard window != 0 else {
            XFreeColormap(display, colormap); XCloseDisplay(display)
            throw X11WindowError.allocationFailed
        }
        self.display = display; self.window = window; self.visual = visual
        self.root = root; self.colormap = colormap; self.frame = bounds
        self.deleteAtom = XInternAtom(display, "WM_DELETE_WINDOW", 0)
        var protocolAtom = deleteAtom
        XSetWMProtocols(display, window, &protocolAtom, 1)
        XStoreName(display, window, "DynaPet")
        let className = strdup("dynapet")!, classClass = strdup("DynaPet")!
        var classHint = XClassHint(res_name: className, res_class: classClass)
        XSetClassHint(display, window, &classHint)
        free(className); free(classClass)
        DynaPetSetBorderless(display, window, XInternAtom(display, "_MOTIF_WM_HINTS", 0))
        var hints = XWMHints()
        hints.flags = InputHint; hints.input = 0
        XSetWMHints(display, window, &hints)
        var types = [XInternAtom(display, "_NET_WM_WINDOW_TYPE_UTILITY", 0)]
        types.withUnsafeBufferPointer { _ = DynaPetSetAtoms(display, window, XInternAtom(display, "_NET_WM_WINDOW_TYPE", 0), $0.baseAddress, 1) }
        var states = ["_NET_WM_STATE_ABOVE", "_NET_WM_STATE_STICKY", "_NET_WM_STATE_SKIP_TASKBAR", "_NET_WM_STATE_SKIP_PAGER"].map { XInternAtom(display, $0, 0) }
        states.withUnsafeBufferPointer { _ = DynaPetSetAtoms(display, window, XInternAtom(display, "_NET_WM_STATE", 0), $0.baseAddress, Int32($0.count)) }
        var desktop: [UInt] = [0xFFFFFFFF]
        desktop.withUnsafeBufferPointer { _ = DynaPetSetCardinals(display, window, XInternAtom(display, "_NET_WM_DESKTOP", 0), $0.baseAddress, 1) }
        XFlush(display)
    }
    private func assertOwner() { precondition(pthread_equal(owner, pthread_self()) != 0, "X11 operations must stay on the window thread") }
    public func setBounds(_ bounds: WindowBounds) {
        assertOwner()
        guard bounds.isValid, abs(bounds.origin.x) < 32768, abs(bounds.origin.y) < 32768,
              bounds.width < 32768, bounds.height < 32768 else { return }
        frame = bounds
        XMoveResizeWindow(display, window, Int32(bounds.origin.x), Int32(bounds.origin.y), UInt32(bounds.width), UInt32(bounds.height))
        XFlush(display)
    }
    public func setAlwaysOnTop(_ enabled: Bool) {
        assertOwner()
        DynaPetSendState(display, root, window, XInternAtom(display, "_NET_WM_STATE", 0), XInternAtom(display, "_NET_WM_STATE_ABOVE", 0), enabled ? 1 : 0)
        XFlush(display)
    }
    public func setVisible(_ visible: Bool) {
        assertOwner()
        if visible { XMapWindow(display, window) } else { XUnmapWindow(display, window) }
        isVisible = visible; XFlush(display)
    }
    public func capturePointer() -> Bool {
        assertOwner()
        return XGrabPointer(display, window, 0, UInt32(ButtonReleaseMask | PointerMotionMask), GrabModeAsync, GrabModeAsync, 0, 0, 0) == GrabSuccess
    }
    public func releasePointer() { assertOwner(); XUngrabPointer(display, 0); XFlush(display) }
    public func cursorPosition() -> DesktopPoint? {
        var rootReturn: Window = 0, childReturn: Window = 0
        var rootX: Int32 = 0, rootY: Int32 = 0, localX: Int32 = 0, localY: Int32 = 0
        var mask: UInt32 = 0
        guard XQueryPointer(display, root, &rootReturn, &childReturn, &rootX, &rootY, &localX, &localY, &mask) != 0 else { return nil }
        return DesktopPoint(x: Double(rootX), y: Double(rootY))
    }
    public func pollEvents() {
        assertOwner()
        var handled = 0
        while XPending(display) > 0 && handled < 1000 {
            handled += 1
            var event = XEvent()
            XNextEvent(display, &event)
            guard event.xany.window == window else { continue }
            switch event.type {
            case Expose: onEvent?(.redraw)
            case ButtonPress:
                onEvent?(.buttonDown(button: event.xbutton.button, cursor: .init(x: Double(event.xbutton.x_root), y: Double(event.xbutton.y_root))))
            case ButtonRelease:
                onEvent?(.buttonUp(button: event.xbutton.button, cursor: .init(x: Double(event.xbutton.x_root), y: Double(event.xbutton.y_root))))
            case MotionNotify:
                // Coalesce stale motion events before forwarding the latest global position.
                while XCheckTypedWindowEvent(display, window, MotionNotify, &event) != 0 {}
                if let cursor = cursorPosition() { onEvent?(.pointerMoved(cursor: cursor)) }
            case ConfigureNotify:
                var translatedX: Int32 = 0, translatedY: Int32 = 0; var child: Window = 0
                XTranslateCoordinates(display, window, root, 0, 0, &translatedX, &translatedY, &child)
                frame = WindowBounds(x: Double(translatedX), y: Double(translatedY), width: Double(event.xconfigure.width), height: Double(event.xconfigure.height))
                onEvent?(.geometryChanged)
            case ClientMessage:
                if Atom(event.xclient.data.l.0) == deleteAtom { onEvent?(.close) }
            default: break
            }
        }
    }
    deinit {
        XUngrabPointer(display, 0)
        XDestroyWindow(display, window)
        XFreeColormap(display, colormap)
        XCloseDisplay(display)
    }
}
#endif
