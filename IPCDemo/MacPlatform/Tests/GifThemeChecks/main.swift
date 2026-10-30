import AppKit
import ImageIO

func require(_ test: @autoclosure () -> Bool, _ label: String) { precondition(test(), label) }
func hash(_ image: NSImage) -> String {
    var rect = CGRect(origin: .zero, size: image.size)
    let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
    let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
    var result: UInt32 = 2166136261
    for i in 0..<(cg.width * cg.height * 4) { let value: UInt8 = i % 4 != 3 && bytes[(i / 4) * 4 + 3] == 0 ? 0 : bytes[i]; result = (result ^ UInt32(value)) &* 16777619 }
    return String(format: "%08x", result)
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fixture = root.appendingPathComponent("TestThemes/MinimalGif")
let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("TestThemes/Conformance/expected.json"))) as! [String: [String: Any]]
for (filename, properties) in expected {
    let file = (filename == "demo.gif" ? fixture : root.appendingPathComponent("TestThemes/Conformance")).appendingPathComponent(filename)
    var budget = 64_000_000
    let clip = try GifClip.load(file, budget: &budget)
    let frames = properties["frames"] as! [[String: Any]]
    require(clip.frames.count == frames.count && clip.frames.count > 3, "all frames decoded")
    let repeats = (properties["repeats"] as? NSNumber)?.intValue
    require(clip.repeats == repeats, "raw repeat count \(filename): \(String(describing: clip.repeats))")
    for i in frames.indices {
        require(abs(clip.delays[i] - (frames[i]["delay"] as! Double)) < 0.000001, "delay \(filename)/\(i)")
        let actual = hash(clip.frames[i]); let want = frames[i]["rgbaFNV1a"] as! String
        require(actual == want, "compositing \(filename)/\(i): \(actual) != \(want)")
    }
    require(clip.index(at: 0) == 0, "start at first")
    require(clip.index(at: 0.041) == (filename == "zero-delay.gif" ? 0 : 1), "per-frame delay")
    if repeats == 0 { require(clip.index(at: clip.duration * 100 + 0.001) == 0, "infinite repeat") }
    else { require(clip.index(at: clip.duration * Double((repeats ?? 0) + 1) + 0.001) == frames.count - 1, "finite freeze last") }
    print("PASS: \(filename): \(frames.count) frames, all delays, loops, composited RGBA")
}
let distinct = try GifTheme(directory: root.appendingPathComponent("TestThemes/Conformance"))
require(distinct.clip(for: .shy).repeats == 2, "touch selects finite.gif")
require(distinct.clip(for: .sleepy).repeats == 0, "sleep selects disposal.gif")
require(distinct.clip(for: .idle).repeats == nil, "idle selects once.gif")
require(distinct.clip(for: .focus).delays[1] == 0.01, "optional mood selects distinct GIF")
var smallBudget = 1
 do { _ = try GifClip.load(fixture.appendingPathComponent("demo.gif"), budget: &smallBudget); preconditionFailure("budget not enforced") } catch { }
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("dynapet-gif-check-" + UUID().uuidString)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let name = try GifTheme.importFolder(fixture, root: temporary)
let loaded = try GifTheme(directory: temporary.appendingPathComponent(name))
for mood in Mood.allCases { require(loaded.clip(for: mood).frames.count == 8, "mapped \(mood)") }
require(loaded.manifest.file(for: .shy) == "demo.gif", "touch alias")
require(loaded.manifest.file(for: .sleepy) == "demo.gif", "sleep alias")
let broken = temporary.appendingPathComponent("bad")
try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
try Data("{\"format\":\"dynapet-theme\",\"version\":1,\"name\":\"bad\",\"states\":{\"idle\":\"../demo.gif\",\"touch\":\"demo.gif\",\"sleep\":\"demo.gif\"}}".utf8).write(to: broken.appendingPathComponent("theme.json"))
do { _ = try GifThemeManifest.read(broken); preconditionFailure("path traversal accepted") } catch { }
let directName = try ThemeImport.make([fixture.appendingPathComponent("demo.gif")], rootOverride: temporary)
let direct = MotionLibrary(directory: temporary.appendingPathComponent(directName))
require(direct.ready && direct.dynamic && direct.clips[.idle]?.frames.count == 8, "single GIF import retains every frame")
let viaFolder = try ThemeImport.make([fixture], rootOverride: temporary)
require(MotionLibrary(directory: temporary.appendingPathComponent(viaFolder)).dynamic, "actual folder importer routes GIF theme")
let truncated = temporary.appendingPathComponent("truncated.gif")
let original = try Data(contentsOf: fixture.appendingPathComponent("demo.gif"))
try original.prefix(original.count - 100).write(to: truncated)
var decodeBudget = 64_000_000
do { _ = try GifClip.load(truncated, budget: &decodeBudget); preconditionFailure("truncated GIF accepted") } catch { }
print("PASS: single GIF and actual folder import preserve all 8 frames")
print("PASS: folder import, 11 state mappings, path traversal rejection; no GUI opened")
