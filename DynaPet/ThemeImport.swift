import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Import images as data only. Original files and earlier themes are never overwritten.
enum ThemeImport {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DynaPet/Themes", isDirectory: true)
    }
    static var active: URL? {
        guard let name = UserDefaults.standard.string(forKey: "themeFolder"), name.hasPrefix("theme-"),
              name == (name as NSString).lastPathComponent else { return nil }
        let folder = root.appendingPathComponent(name, isDirectory: true)
        if let data = try? Data(contentsOf: folder.appendingPathComponent("theme.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["format"] as? String == "dynapet-theme" { return folder }
        return Mood.allCases.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.rawValue + ".png").path) } ? folder : nil
    }
    static func make(_ urls: [URL], rootOverride: URL? = nil) throws -> String {
        if urls.count == 1, (try? urls[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if FileManager.default.fileExists(atPath: urls[0].appendingPathComponent("theme.json").path) { return try importPrepared(urls[0], rootOverride: rootOverride) }
            let images = try FileManager.default.contentsOfDirectory(at: urls[0], includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).filter { ["png", "jpg", "jpeg", "gif", "bmp"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            return try make(images, rootOverride: rootOverride)
        }
        if urls.contains(where: { $0.pathExtension.lowercased() == "gif" }) {
            guard urls.count == 1 else { throw failure("多份 GIF 请通过 theme.json 映射后导入主题包，避免丢失动画。") }
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("dynapet-gif-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let values = try urls[0].resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 32 * 1024 * 1024 else { throw failure("GIF 必须是小于 32 MiB 的普通文件。") }
            try FileManager.default.copyItem(at: urls[0], to: staging.appendingPathComponent("animation.gif"))
            let manifest = GifThemeManifest(format: "dynapet-theme", version: 1, name: "Imported GIF", states: ["idle": "animation.gif", "touch": "animation.gif", "sleep": "animation.gif"])
            try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("theme.json"))
            return try GifTheme.importFolder(staging, root: rootOverride ?? root)
        }
        guard (1...11).contains(urls.count) else { throw NSError(domain: "ThemeImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "请选择 1～11 张图片。单图会复用于全部心情，不会自动生成不同表情。"] ) }
        var images: [String: [NSImage]] = [:]
        for url in urls {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 32 * 1024 * 1024,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw failure("图片格式无效或文件超过 32 MB。") }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            guard width > 0, height > 0, Double(width) * Double(height) <= 32_000_000 else { throw failure("图片尺寸过大，请使用不超过 3200 万像素的图片。") }
            var frames: [NSImage] = []
            for index in 0..<1 {
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 512, kCGImageSourceCreateThumbnailWithTransform: true]
                guard let cg = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { throw failure("无法解码角色图片。") }
                frames.append(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
            }
            guard !frames.isEmpty else { throw failure("图片没有可读取的帧。") }
            images[url.deletingPathExtension().lastPathComponent.lowercased()] = frames
        }
        let firstName = urls[0].deletingPathExtension().lastPathComponent.lowercased()
        guard let fallback = images["idle"] ?? images[firstName] else { throw failure("缺少可读取的角色图片。") }
        let name = "theme-" + UUID().uuidString.lowercased()
        let folder = (rootOverride ?? root).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for mood in Mood.allCases {
            let frames = images[mood.rawValue] ?? fallback
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 768, pixelsHigh: 256, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw failure("无法生成主题图片。") }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: 768, height: 256).fill(using: .copy)
            for frame in 0..<3 {
                let image = frames[frame % frames.count]
                let ratio = min(224 / image.size.width, 224 / image.size.height)
                let size = NSSize(width: image.size.width * ratio, height: image.size.height * ratio)
                image.draw(in: NSRect(x: Double(frame * 256) + (256 - size.width) / 2, y: (256 - size.height) / 2, width: size.width, height: size.height))
            }
            NSGraphicsContext.restoreGraphicsState()
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw failure("无法编码主题图片。") }
            try png.write(to: folder.appendingPathComponent(mood.rawValue + ".png"), options: .atomic)
        }
        let metadata: [String: Any] = ["version": 1, "layout": "three-frame-strip", "moods": Mood.allCases.map(\.rawValue), "rights": "User-provided images; original rights retained"]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted]).write(to: folder.appendingPathComponent("theme.json"), options: .atomic)
        guard MotionLibrary(directory: folder).ready else { throw failure("主题缺少有效的可见图像，未切换原角色。") }
        return name
    }
    private static func importPrepared(_ source: URL, rootOverride: URL?) throws -> String {
        let manifestFile = source.appendingPathComponent("theme.json")
        guard (try manifestFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 65536 else { throw failure("主题描述文件过大。") }
        let data = try Data(contentsOf: manifestFile)
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], json["format"] as? String == "dynapet-theme" { return try GifTheme.importFolder(source, root: rootOverride ?? root) }
        guard data.count <= 65536, let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["version"] as? Int == 1, manifest["layout"] as? String == "three-frame-strip" else { throw failure("不支持的主题格式。") }
        for mood in Mood.allCases {
            let file = source.appendingPathComponent(mood.rawValue + ".png")
            guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 32 * 1024 * 1024,
                  let image = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                  (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 768,
                  (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 256 else { throw failure("主题图片应为 768×256 横向三帧。") }
        }
        guard MotionLibrary(directory: source).ready else { throw failure("主题图片缺少有效的可见内容。") }
        let name = "theme-" + UUID().uuidString.lowercased(); let target = (rootOverride ?? root).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for mood in Mood.allCases { let file = mood.rawValue + ".png"; try FileManager.default.copyItem(at: source.appendingPathComponent(file), to: target.appendingPathComponent(file)) }
        try data.write(to: target.appendingPathComponent("theme.json"), options: .atomic)
        return name
    }
    private static func failure(_ text: String) -> NSError { NSError(domain: "ThemeImport", code: 2, userInfo: [NSLocalizedDescriptionKey: text]) }
}
