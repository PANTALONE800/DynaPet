import Foundation

public enum PetWindowFailure: Error {
    case invalidArgument, unsupportedAnimation, assetUnavailable, windowUnavailable
}
public typealias PetWindowCompletion = (Result<Void, PetWindowFailure>) -> Void

/// Coordinates are logical desktop points, origin at the desktop's top-left.
/// Success means the adapter has applied the operation, not merely queued it.
/// Native UI types and handles must remain inside the platform adapter.
public protocol PetWindowHandling: AnyObject {
    func showWindow(completion: @escaping PetWindowCompletion)
    func setAlwaysOnTop(_ isOn: Bool, completion: @escaping PetWindowCompletion)
    func setClickThrough(_ isOn: Bool, completion: @escaping PetWindowCompletion)
    func updatePosition(x: Double, y: Double, completion: @escaping PetWindowCompletion)
    func updateSize(scale: Double, completion: @escaping PetWindowCompletion)
    func playAnimation(name: String, completion: @escaping PetWindowCompletion)
    func updateStatusText(_ text: String, completion: @escaping PetWindowCompletion)
    func closeWindow(completion: @escaping PetWindowCompletion)
}
public extension PetWindowHandling {
    func showWindow() { showWindow(completion: { _ in }) }
    func setAlwaysOnTop(_ isOn: Bool) { setAlwaysOnTop(isOn, completion: { _ in }) }
    func setClickThrough(_ isOn: Bool) { setClickThrough(isOn, completion: { _ in }) }
    func updatePosition(x: Double, y: Double) { updatePosition(x: x, y: y, completion: { _ in }) }
    func updateSize(scale: Double) { updateSize(scale: scale, completion: { _ in }) }
    func playAnimation(name: String) { playAnimation(name: name, completion: { _ in }) }
    func updateStatusText(_ text: String) { updateStatusText(text, completion: { _ in }) }
    func closeWindow() { closeWindow(completion: { _ in }) }
}
