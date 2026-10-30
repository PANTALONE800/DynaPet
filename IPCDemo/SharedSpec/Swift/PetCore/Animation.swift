import Foundation
public extension Mood {
    var animationTiming: (duration: Double, period: Double) {
        switch self {
        case .idle: return (0.30, 4.6)
        case .welcome: return (0.40, 3.8)
        case .message: return (0.32, 4.0)
        case .happy: return (0.34, 3.9)
        case .puzzled: return (0.34, 4.4)
        case .focus: return (1.15, 3.4)
        case .hot: return (1.20, 2.7)
        case .low: return (1.15, 3.1)
        case .shy: return (0.85, 3.5)
        case .sleepy: return (2.2, 5.0)
        case .dizzy: return (1.9, 2.0)
        }
    }
    func animationFrame(at time: Double) -> Int {
        let timing = animationTiming
        let phase = ((time.truncatingRemainder(dividingBy: timing.period)) + timing.period).truncatingRemainder(dividingBy: timing.period)
        guard phase >= timing.period - timing.duration else { return 0 }
        let index = min(5, max(0, Int((phase - timing.period + timing.duration) / timing.duration * 6)))
        return [0, 1, 2, 2, 1, 0][index]
    }
}
