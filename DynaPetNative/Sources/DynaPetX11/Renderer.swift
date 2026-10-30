#if os(Linux)
import Foundation
import PetCore
import Windowing
import CX11
import CCairo
import CGTK3

enum RenderError: Error { case missingImage(String), allocationFailed }
final class X11Renderer {
    struct Clip { let surface: OpaquePointer; let cell: Int; let x: Int; let y: Int; let width: Int; let height: Int }
    private var clips: [Mood: Clip] = [:]
    private let manager: X11WindowManager
    private var canvas: OpaquePointer
    private var context: OpaquePointer
    private let target: OpaquePointer
    private let targetContext: OpaquePointer
    private var width: Int32
    private var height: Int32
    init(manager: X11WindowManager, assets: URL) throws {
        self.manager = manager
        width = Int32(manager.bounds.width); height = Int32(manager.bounds.height)
        guard let canvas = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height),
              let context = cairo_create(canvas),
              let target = cairo_xlib_surface_create(manager.display, manager.window, manager.visual, width, height),
              let targetContext = cairo_create(target) else { throw RenderError.allocationFailed }
        self.canvas = canvas; self.context = context; self.target = target; self.targetContext = targetContext
        for mood in Mood.allCases {
            let file = assets.appendingPathComponent(mood.rawValue + ".png").path
            guard let image = cairo_image_surface_create_from_png(file), cairo_surface_status(image) == CAIRO_STATUS_SUCCESS else { throw RenderError.missingImage(file) }
            cairo_surface_flush(image)
            let cell = Int(cairo_image_surface_get_width(image)) / 3, h = Int(cairo_image_surface_get_height(image))
            let stride = Int(cairo_image_surface_get_stride(image))
            guard let pixels = cairo_image_surface_get_data(image), cell > 0 else { cairo_surface_destroy(image); throw RenderError.missingImage(file) }
            var left = cell, right = 0, top = h, bottom = 0
            for frame in 0..<3 {
                var xs = [Int](repeating: 0, count: cell), ys = [Int](repeating: 0, count: h)
                for y in 0..<h { for x in 0..<cell where pixels[y * stride + (frame * cell + x) * 4 + 3] > 180 { xs[x] += 1; ys[y] += 1 } }
                if let l = xs.firstIndex(where: { $0 > 4 }), let r = xs.lastIndex(where: { $0 > 4 }),
                   let t = ys.firstIndex(where: { $0 > 4 }), let b = ys.lastIndex(where: { $0 > 4 }) {
                    left = min(left, l); right = max(right, r); top = min(top, t); bottom = max(bottom, b)
                }
            }
            guard left < right, top < bottom else { cairo_surface_destroy(image); throw RenderError.missingImage(file) }
            left = max(0, left - 3); top = max(0, top - 3); right = min(cell - 1, right + 3); bottom = min(h - 1, bottom + 3)
            clips[mood] = Clip(surface: image, cell: cell, x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        }
    }
    func resized() {
        let newWidth = Int32(manager.bounds.width), newHeight = Int32(manager.bounds.height)
        guard newWidth != width || newHeight != height else { return }
        width = newWidth; height = newHeight
        cairo_destroy(context); cairo_surface_destroy(canvas)
        canvas = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height)!
        context = cairo_create(canvas)!
        cairo_xlib_surface_set_size(target, width, height)
    }
    private func roundedBox(x: Double, y: Double, width: Double, height: Double, radius: Double = 14) {
        cairo_new_sub_path(context)
        cairo_arc(context, x + width - radius, y + radius, radius, -.pi / 2, 0)
        cairo_arc(context, x + width - radius, y + height - radius, radius, 0, .pi / 2)
        cairo_arc(context, x + radius, y + height - radius, radius, .pi / 2, .pi)
        cairo_arc(context, x + radius, y + radius, radius, .pi, .pi * 1.5)
        cairo_close_path(context)
        cairo_set_source_rgba(context, 0.97, 0.97, 0.95, 0.94); cairo_fill(context)
    }
    private func text(_ value: String, x: Double, y: Double, width: Int, font: String = "Sans 11") {
        guard let layout = pango_cairo_create_layout(context), let description = pango_font_description_from_string(font) else { return }
        pango_layout_set_font_description(layout, description)
        pango_layout_set_width(layout, Int32(width) * 1024)
        pango_layout_set_wrap(layout, PANGO_WRAP_WORD_CHAR)
        pango_layout_set_text(layout, value, -1)
        cairo_move_to(context, x, y); cairo_set_source_rgb(context, 0.17, 0.17, 0.17)
        pango_cairo_show_layout(context, layout)
        pango_font_description_free(description)
        g_object_unref(UnsafeMutableRawPointer(layout))
    }
    func draw(mood: Mood, text bubble: String, time: Double, scale: Double, details: String?) {
        resized()
        cairo_save(context); cairo_set_operator(context, CAIRO_OPERATOR_CLEAR); cairo_paint(context); cairo_restore(context)
        let bottom = Double(height), spriteHeight = 200 * scale
        if let details {
            roundedBox(x: 10, y: 10, width: Double(width) - 20, height: bottom - spriteHeight - 125)
            text(details, x: 22, y: 22, width: Int(width) - 44, font: "Sans 9")
        }
        roundedBox(x: 20, y: bottom - spriteHeight - 102, width: Double(width) - 40, height: 65)
        text(bubble, x: 32, y: bottom - spriteHeight - 92, width: Int(width) - 64)
        if let clip = clips[mood] {
            let ratio = min(210 * scale / Double(clip.width), 178 * scale / Double(clip.height))
            let w = Double(clip.width) * ratio, h = Double(clip.height) * ratio
            cairo_save(context)
            cairo_translate(context, Double(width) / 2 - w / 2, bottom - 40 - h)
            cairo_scale(context, ratio, ratio)
            cairo_rectangle(context, 0, 0, Double(clip.width), Double(clip.height)); cairo_clip(context)
            cairo_set_source_surface(context, clip.surface, -Double(mood.animationFrame(at: time) * clip.cell + clip.x), -Double(clip.y))
            cairo_paint(context); cairo_restore(context)
        }
        roundedBox(x: 70, y: bottom - 32, width: Double(width) - 140, height: 24, radius: 12)
        text(mood.title + "  ·  右键菜单", x: 81, y: bottom - 29, width: Int(width) - 155, font: "Sans 9")
        cairo_surface_flush(canvas)
        cairo_set_operator(targetContext, CAIRO_OPERATOR_SOURCE)
        cairo_set_source_surface(targetContext, canvas, 0, 0); cairo_paint(targetContext)
        cairo_surface_flush(target); XFlush(manager.display)
    }
    func savePNG(to path: String) throws {
        guard cairo_surface_write_to_png(canvas, path) == CAIRO_STATUS_SUCCESS else { throw RenderError.allocationFailed }
    }
    deinit {
        for clip in clips.values { cairo_surface_destroy(clip.surface) }
        cairo_destroy(context); cairo_surface_destroy(canvas)
        cairo_destroy(targetContext); cairo_surface_destroy(target)
    }
}
#endif
