using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage.Streams;

namespace DynaPet.Windows;

internal sealed class OcrUnavailableException : Exception
{
    internal OcrUnavailableException(string message) : base(message) { }
}
internal static class WindowOcr
{
    internal static async Task<string> Read(IntPtr window)
    {
        // Invoked only after explicit selection and consent, never by a background scan.
        if (window == IntPtr.Zero || Native.Owner(window) == Environment.ProcessId || !Native.GetWindowRect(window, out var rect))
            throw new OcrUnavailableException("目标窗口已关闭或无效，请先选中要识别的窗口，再打开识别菜单。");
        if (Native.IsIconic(window)) throw new OcrUnavailableException("目标窗口已最小化，请恢复窗口后重试。");
        var engine = OcrEngine.TryCreateFromUserProfileLanguages();
        if (engine == null && OcrEngine.AvailableRecognizerLanguages.FirstOrDefault() is { } language)
            engine = OcrEngine.TryCreateFromLanguage(language);
        if (engine == null) throw new OcrUnavailableException("未安装可用的 Windows OCR 语言包。请从菜单打开“OCR 语言包设置”，安装对应语言的文字识别组件。");
        var width = rect.Right - rect.Left; var height = rect.Bottom - rect.Top;
        if (width < 24 || height < 24 || width > 8192 || height > 8192)
            throw new OcrUnavailableException("窗口尺寸不适合识别，请调整窗口大小后重试。");
        using var image = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(image))
        {
            var dc = graphics.GetHdc();
            try { if (!Native.PrintWindow(window, dc, 2)) throw new OcrUnavailableException("系统未能捕获此窗口。受保护、不同权限或部分硬件渲染窗口不支持此方式。"); }
            finally { graphics.ReleaseHdc(dc); }
        }
        // Large/high-DPI windows must be scaled to the engine's actual limit, not dropped silently.
        var ratio = Math.Min(1.0, (double)OcrEngine.MaxImageDimension / Math.Max(width, height));
        using var scaled = ratio < 1 ? new Bitmap(Math.Max(1, (int)(width * ratio)), Math.Max(1, (int)(height * ratio)), PixelFormat.Format32bppArgb) : null;
        if (scaled != null)
        {
            using var graphics = Graphics.FromImage(scaled);
            graphics.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
            graphics.DrawImage(image, 0, 0, scaled.Width, scaled.Height);
        }
        using var memory = new MemoryStream(); (scaled ?? image).Save(memory, ImageFormat.Png);
        using var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream)) { writer.WriteBytes(memory.ToArray()); await writer.StoreAsync(); writer.DetachStream(); }
        stream.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(stream);
        using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
        var result = await engine.RecognizeAsync(bitmap);
        return result.Text.Length > 6000 ? result.Text[..6000] : result.Text;
    }
}
