import Foundation

/// Desktop coordinates use a top-left origin, with y increasing downwards.
/// AppKit's bottom-left coordinate conversion belongs to its adapter.
public struct DesktopPoint: Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}
public struct WindowBounds: Equatable {
    public var origin: DesktopPoint
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.origin = DesktopPoint(x: x, y: y); self.width = width; self.height = height
    }
    public var isValid: Bool {
        [origin.x, origin.y, width, height].allSatisfy(\.isFinite) && width >= 1 && height >= 1
    }
}

/// A backend owns its native resources. Business rules never receive native
/// window handles, NSEvents, XEvent pointers, or platform-specific coordinates.
public protocol WindowManager: AnyObject {
    var bounds: WindowBounds { get }
    func setBounds(_ bounds: WindowBounds)
    func setAlwaysOnTop(_ enabled: Bool)
    func setVisible(_ visible: Bool)
}

/// Drag deltas come exclusively from desktop coordinates; window movement must
/// not change the coordinate system used to compute the next drag sample.
public struct WindowDrag {
    private var start: (cursor: DesktopPoint, window: WindowBounds)?
    public init() {}
    public mutating func begin(cursor: DesktopPoint, bounds: WindowBounds) {
        start = (cursor, bounds)
    }
    public func updated(cursor: DesktopPoint) -> WindowBounds? {
        guard let start else { return nil }
        var result = start.window
        result.origin.x += cursor.x - start.cursor.x
        result.origin.y += cursor.y - start.cursor.y
        return result
    }
    @discardableResult public mutating func end(cursor: DesktopPoint) -> Bool {
        defer { start = nil }
        guard let start else { return false }
        return hypot(cursor.x - start.cursor.x, cursor.y - start.cursor.y) >= 4
    }
}
