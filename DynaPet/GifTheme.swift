import AppKit
import ImageIO

/// SharedSpec/ThemePackageSpec.md is the contract for both native implementations.
struct GifThemeManifest: Codable {
    let format: String
    let version: Int
    let name: String
    let states: [String: String]
    static func read(_ directory: URL) throws -> Self {
        let file = directory.appendingPathComponent("theme.json")
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 65536 else { throw failure("theme.json 超过 64 KiB。") }
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        let allowed = Set(["idle", "touch", "sleep", "welcome", "focus", "happy", "hot", "dizzy", "puzzled", "low", "message"])
        guard manifest.format == "dynapet-theme", manifest.version == 1,
              !manifest.name.isEmpty, manifest.name.utf8.count <= 128,
              ["idle", "touch", "sleep"].allSatisfy({ manifest.states[$0] != nil }),
              Set(manifest.states.keys).isSubset(of: allowed) else { throw failure("不支持的动态主题配置。") }
        for filename in manifest.states.values {
            guard filename.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}\\.gif$", options: .regularExpression) != nil else { throw failure("GIF 文件名只能使用英文、数字、下划线和连字符。") }
            let url = directory.appendingPathComponent(filename)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? Int.max) <= 32 * 1024 * 1024 else { throw failure("GIF 必须是小于 32 MiB 的普通文件。") }
        }
        return manifest
    }
    func file(for mood: Mood) -> String {
        let key = mood == .shy ? "touch" : mood == .sleepy ? "sleep" : mood.rawValue
        return states[key] ?? states["idle"]!
    }
    static func failure(_ text: String) -> NSError { NSError(domain: "GifTheme", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}

struct GifClip {
    let frames: [NSImage]
    let delays: [Double]
    /// nil: no loop extension (one pass); 0: forever; positive: repeats after first pass.
    let repeats: Int?
    var duration: Double { delays.reduce(0, +) }
    func index(at elapsed: Double) -> Int {
        let elapsed = max(0, elapsed)
        if let repeats, repeats == 0 { /* infinite */ }
        else if elapsed >= duration * Double((repeats ?? 0) + 1) { return frames.count - 1 }
        let phase = elapsed.truncatingRemainder(dividingBy: duration)
        var boundary = 0.0
        for (i, delay) in delays.enumerated() { boundary += delay; if phase < boundary { return i } }
        return frames.count - 1
    }
    static func load(_ url: URL, budget: inout Int) throws -> Self {
        let structure = try GifStructure.read(url)
        guard structure.width * structure.height * structure.count <= budget else { throw GifThemeManifest.failure("主题解码资源超限。") }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetType(source) as String? == "com.compuserve.gif",
              let global = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
              let canvas = global[kCGImagePropertyGIFDictionary] as? [CFString: Any],
              let width = canvas[kCGImagePropertyGIFCanvasPixelWidth] as? Int,
              let height = canvas[kCGImagePropertyGIFCanvasPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096 else { throw GifThemeManifest.failure("无效 GIF 或画布超过 4096×4096。") }
        guard CGImageSourceGetStatus(source) == .statusComplete else { throw GifThemeManifest.failure("GIF 数据不完整。") }
        let count = CGImageSourceGetCount(source)
        guard count == structure.count, width == structure.width, height == structure.height, count > 0, count <= 1000, width * height * count <= budget else { throw GifThemeManifest.failure("主题解码总量超过 6400 万像素，或 GIF 超过 1000 帧。不会截断播放。") }
        budget -= width * height * count
        let globalGif = global[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        // ImageIO reports total passes (missing extension => 1, raw 2 => 3).
        // Normalize to the shared raw-repeat convention used by GDI+.
        let passes = (globalGif?[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue
        let repeats: Int? = passes == 0 ? 0 : passes.flatMap { $0 > 1 ? $0 - 1 : nil }
        var frames: [NSImage] = [], delays: [Double] = []
        for i in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, i, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any] else { throw GifThemeManifest.failure("GIF 第 \(i + 1) 帧解码失败。") }
            let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0
            frames.append(NSImage(cgImage: image, size: NSSize(width: width, height: height)))
            delays.append(delay > 0 ? delay : 0.1)
        }
        return Self(frames: frames, delays: delays, repeats: repeats)
    }
}

final class GifTheme {
    let manifest: GifThemeManifest
    let clips: [String: GifClip]
    init(directory: URL) throws {
        manifest = try GifThemeManifest.read(directory)
        var loaded: [String: GifClip] = [:], budget = 64_000_000, bytes = 0
        for file in Set(manifest.states.values).sorted() {
            let url = directory.appendingPathComponent(file)
            bytes += try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard bytes <= 64 * 1024 * 1024 else { throw GifThemeManifest.failure("主题 GIF 总文件大小超过 64 MiB。") }
            loaded[file] = try GifClip.load(url, budget: &budget)
        }
        clips = loaded
    }
    func clip(for mood: Mood) -> GifClip { clips[manifest.file(for: mood)]! }
    static func importFolder(_ source: URL, root: URL) throws -> String {
        let manifest = try GifThemeManifest.read(source)
        let name = "theme-" + UUID().uuidString.lowercased()
        let target = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        do {
            // Copy only manifest-listed data. No links, executables or traversal paths.
            for file in Set(manifest.states.values) { try FileManager.default.copyItem(at: source.appendingPathComponent(file), to: target.appendingPathComponent(file)) }
            try JSONEncoder().encode(manifest).write(to: target.appendingPathComponent("theme.json"), options: .atomic)
            _ = try GifTheme(directory: target)
            return name
        } catch { try? FileManager.default.removeItem(at: target); throw error }
    }
}

/// ImageIO may successfully expose a prefix of a truncated GIF. Verify block
/// completeness and frame count before trusting its otherwise complete status.
struct GifStructure {
    let width: Int, height: Int, count: Int
    static func read(_ url: URL) throws -> Self {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 32 * 1024 * 1024 else { throw GifThemeManifest.failure("GIF 超过 32 MiB。") }
        let data = [UInt8](try Data(contentsOf: url))
        var position = 0
        func bytes(_ count: Int) throws -> [UInt8] {
            guard count >= 0, position <= data.count - count else { throw GifThemeManifest.failure("GIF 数据不完整。") }
            defer { position += count }
            return Array(data[position..<(position + count)])
        }
        func byte() throws -> Int { Int(try bytes(1)[0]) }
        func word() throws -> Int { let b = try bytes(2); return Int(b[0]) | Int(b[1]) << 8 }
        func blocks() throws {
            var size = try byte()
            while size != 0 { _ = try bytes(size); size = try byte() }
        }
        let header = String(bytes: try bytes(6), encoding: .ascii)
        guard header == "GIF87a" || header == "GIF89a" else { throw GifThemeManifest.failure("不是 GIF。") }
        let width = try word(), height = try word()
        var packed = try byte(); _ = try bytes(2)
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { throw GifThemeManifest.failure("GIF 画布超过 4096×4096。") }
        if packed & 128 != 0 { _ = try bytes(3 * (1 << ((packed & 7) + 1))) }
        var count = 0
        while true {
            switch try byte() {
            case 0x3b:
                guard count > 0 else { throw GifThemeManifest.failure("GIF 无帧。") }
                return Self(width: width, height: height, count: count)
            case 0x21: _ = try byte(); try blocks()
            case 0x2c:
                _ = try bytes(4)
                let w = try word(), h = try word(); packed = try byte()
                guard w > 0, h > 0, w <= width, h <= height else { throw GifThemeManifest.failure("无效 GIF 帧尺寸。") }
                if packed & 128 != 0 { _ = try bytes(3 * (1 << ((packed & 7) + 1))) }
                _ = try byte(); try blocks(); count += 1
                guard count <= 1000, width * height * count <= 64_000_000 else { throw GifThemeManifest.failure("GIF 解码资源超限，不会截断。") }
            default: throw GifThemeManifest.failure("无效 GIF 块。")
            }
        }
    }
}
