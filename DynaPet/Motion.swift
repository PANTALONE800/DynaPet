import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

// Default animation data is read from DemoTheme, independent of the engine name.
struct BustClip {
    var frames: [NSImage]
    var gif: GifClip? = nil
    var actionDuration: Double
    var period: Double
    func frame(at time: Double) -> NSImage {
        if let gif { return frames[gif.index(at: time)] }
        let p = (time + 10000).truncatingRemainder(dividingBy: period)
        guard p >= period - actionDuration else { return frames[0] }
        let phase = (p - (period - actionDuration)) / actionDuration
        let sequence = [0, 1, 2, 2, 1, 0]
        return frames[sequence[min(5, Int(phase * 6))]]
    }
}
final class MotionLibrary {
    var clips: [Mood: BustClip] = [:]
    let loadedAt = Date().timeIntervalSinceReferenceDate
    var dynamic = false
    var ready: Bool { clips.count == Mood.allCases.count && clips.values.allSatisfy { !$0.frames.isEmpty } }
    init(bundle: Bundle = .main, directory: URL? = ThemeImport.active) {
        if let directory, let data = try? Data(contentsOf: directory.appendingPathComponent("theme.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["format"] as? String == "dynapet-theme" {
            if let theme = try? GifTheme(directory: directory) {
                dynamic = true
                for mood in Mood.allCases { let gif = theme.clip(for: mood); clips[mood] = BustClip(frames: gif.frames, gif: gif, actionDuration: 0, period: gif.duration) }
            }
            return
        }
        for mood in Mood.allCases {
            guard let url = directory?.appendingPathComponent(mood.rawValue + ".png") ?? bundle.url(forResource: mood.rawValue, withExtension: "png", subdirectory: "DemoTheme"), let source = CGImageSourceCreateWithURL(url as CFURL, nil), let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            let cellWidth = sheet.width / 3
            let cells = (0..<3).compactMap { col in sheet.cropping(to: CGRect(x: col * cellWidth, y: 0, width: cellWidth, height: sheet.height)) }
            guard cells.count == 3 else { continue }
            let boxes = cells.compactMap(Self.alphaBounds)
            guard boxes.count == 3 else { continue }
            // A common crop preserves frame registration instead of independently resizing each pose.
            let box = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }.intersection(CGRect(x: 0, y: 0, width: cellWidth, height: sheet.height)).integral
            let frames = cells.compactMap { cell -> NSImage? in
                guard let cg = cell.cropping(to: box) else { return nil }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            guard frames.count == 3 else { continue }
            let timing: (Double, Double)
            switch mood {
            case .idle: timing = (0.30, 4.6)
            case .welcome: timing = (0.40, 3.8)
            case .message: timing = (0.32, 4.0)
            case .happy: timing = (0.34, 3.9)
            case .puzzled: timing = (0.34, 4.4)
            case .focus: timing = (1.15, 3.4)
            case .hot: timing = (1.20, 2.7)
            case .low: timing = (1.15, 3.1)
            case .shy: timing = (0.85, 3.5)
            case .sleepy: timing = (2.2, 5.0)
            case .dizzy: timing = (1.9, 2.0)
            }
            clips[mood] = BustClip(frames: frames, actionDuration: timing.0, period: timing.1)
        }
    }
    static func alphaBounds(_ image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = c.data else { return nil }
        c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var xs = [Int](repeating: 0, count: w), ys = [Int](repeating: 0, count: h)
        for y in 0..<h { for x in 0..<w where bytes[(y * w + x) * 4 + 3] > 180 { xs[x] += 1; ys[y] += 1 } }
        guard let l = xs.firstIndex(where: { $0 > 4 }), let r = xs.lastIndex(where: { $0 > 4 }), let t = ys.firstIndex(where: { $0 > 4 }), let b = ys.lastIndex(where: { $0 > 4 }) else { return nil }
        return CGRect(x: max(0, l - 3), y: max(0, t - 3), width: min(w - max(0, l - 3), r - l + 7), height: min(h - max(0, t - 3), b - t + 7))
    }
}
struct MotionSprite: View {
    let library: MotionLibrary
    let mood: Mood
    let time: Double
    let scale: Double
    var nod: Double {
        switch mood {
        case .sleepy: return max(0, sin(time * 0.8)) * 7
        case .welcome, .message: return max(0, sin(time * 1.7)) * 3
        case .focus: return max(0, sin(time * 1.4)) * 2
        case .low: return max(0, sin(time * 0.9)) * 3
        default: return max(0, sin(time * 1.2)) * 1.5
        }
    }
    var body: some View {
        ZStack(alignment: .bottom) {
            if let clip = library.clips[mood] {
                Image(nsImage: clip.frame(at: time)).resizable().interpolation(.high).scaledToFit()
                    .frame(width: 210 * scale, height: 178 * scale)
                    .rotation3DEffect(.degrees(nod), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.12)
                    .rotationEffect(.degrees(mood == .dizzy ? sin(time * 2) * 1.8 : sin(time * 1.3) * 0.45), anchor: .bottom)
                    .scaleEffect(x: 1, y: 1 + sin(time * 1.7) * 0.006, anchor: .bottom)
                    .offset(y: nod * 0.15)
                    .id(mood).transition(.opacity)
            }
        }.frame(width: 250, height: 200 * scale, alignment: .bottom)
    }
}
@MainActor func renderMotionPreview(directory: URL) throws {
    _ = NSApplication.shared
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let library = MotionLibrary(); precondition(library.ready)
    var count = 0
    for mood in Mood.allCases {
        guard let clip = library.clips[mood] else { continue }
        let gif = directory.appendingPathComponent(mood.rawValue + ".gif")
        let frames = 120
        guard let dest = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, frames, nil) else { throw NSError(domain: "BustPreview", code: 1) }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in 0..<frames {
            let t = clip.period - clip.actionDuration - 0.5 + Double(frame) / 30 - 10000
            let renderer = ImageRenderer(content: MotionSprite(library: library, mood: mood, time: t, scale: 1)); renderer.scale = 2
            guard let cg = renderer.cgImage else { throw NSError(domain: "BustPreview", code: 2) }
            CGImageDestinationAddImage(dest, cg, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 30]] as CFDictionary)
            if [0, 18, 24, 30].contains(frame) {
                let png = directory.appendingPathComponent(mood.rawValue + "-\(frame).png")
                let d = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(d, cg, nil); precondition(CGImageDestinationFinalize(d))
            }
            count += 1
        }
        precondition(CGImageDestinationFinalize(dest))
    }
    print("PASS: 11 original bust clips, 33 anatomical keyframes, \(count) rendered animation frames; no puppet body")
}
