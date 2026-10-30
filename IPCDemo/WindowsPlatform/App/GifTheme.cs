using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using DynaPet.Core;
using Drawing = System.Drawing;
using Imaging = System.Drawing.Imaging;

namespace DynaPet.Windows;

internal sealed record GifClip(BitmapSource[] Frames, GifTimeline Timeline)
{
    internal static GifClip Load(string path, ref long budget)
    {
        var metadata = GifMetadata.Read(path);
        if ((long)metadata.Width * metadata.Height * metadata.Delays.Length > budget) throw new InvalidDataException("主题解码资源超限。");
        using var stream = File.OpenRead(path);
        using var image = Drawing.Image.FromStream(stream, false, true);
        if (image.RawFormat.Guid != Imaging.ImageFormat.Gif.Guid || image.Width is < 1 or > 4096 || image.Height is < 1 or > 4096)
            throw new InvalidDataException("无效 GIF 或画布超过 4096×4096。");
        var count = image.GetFrameCount(Imaging.FrameDimension.Time);
        var pixels = (long)image.Width * image.Height * count;
        if (count is < 1 or > 1000 || pixels > budget) throw new InvalidDataException("主题解码总量超过 6400 万像素，或 GIF 超过 1000 帧。不会截断播放。");
        budget -= pixels;
        if (count != metadata.Delays.Length || image.Width != metadata.Width || image.Height != metadata.Height) throw new InvalidDataException("原生解码结果与 GIF 结构不一致。");
        int? repeats = metadata.Repeats;
        var frames = new BitmapSource[count];
        for (var i = 0; i < count; i++)
        {
            image.SelectActiveFrame(Imaging.FrameDimension.Time, i);
            // GDI+ performs GIF palette, transparency, offset and disposal composition.
            // Copy every composited canvas into an independent frozen WPF bitmap.
            using var bitmap = new Drawing.Bitmap(image.Width, image.Height, Imaging.PixelFormat.Format32bppArgb);
            using (var graphics = Drawing.Graphics.FromImage(bitmap))
            {
                graphics.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy;
                graphics.DrawImage(image, new Drawing.Rectangle(0, 0, image.Width, image.Height));
            }
            var data = bitmap.LockBits(new Drawing.Rectangle(0, 0, image.Width, image.Height), Imaging.ImageLockMode.ReadOnly, Imaging.PixelFormat.Format32bppArgb);
            try
            {
                var stride = image.Width * 4; var bytes = new byte[stride * image.Height];
                for (var y = 0; y < image.Height; y++) Marshal.Copy(IntPtr.Add(data.Scan0, y * data.Stride), bytes, y * stride, stride);
                frames[i] = BitmapSource.Create(image.Width, image.Height, 96, 96, PixelFormats.Bgra32, null, bytes, stride);
                frames[i].Freeze();
            }
            finally { bitmap.UnlockBits(data); }
        }
        return new(frames, new GifTimeline(metadata.Delays, repeats));
    }
}

internal sealed class GifTheme
{
    internal ThemeManifest Manifest { get; }
    internal Dictionary<string, GifClip> Clips { get; } = new(StringComparer.Ordinal);
    internal GifTheme(string directory)
    {
        Manifest = ThemeManifest.Read(directory);
        long budget = 64_000_000, bytes = 0;
        foreach (var file in Manifest.States.Values.Distinct(StringComparer.Ordinal).Order())
        {
            var path = Path.Combine(directory, file); bytes += new FileInfo(path).Length;
            if (bytes > 64 * 1024 * 1024) throw new InvalidDataException("主题 GIF 总文件大小超过 64 MiB。");
            Clips[file] = GifClip.Load(path, ref budget);
        }
    }
    internal GifClip Clip(Mood mood) => Clips[Manifest.FileFor(mood)];
    internal static string Import(string source, string root)
    {
        var manifest = ThemeManifest.Read(source);
        var name = "theme-" + Guid.NewGuid().ToString("N"); var target = Path.Combine(root, name);
        Directory.CreateDirectory(target);
        try
        {
            foreach (var file in manifest.States.Values.Distinct(StringComparer.Ordinal)) File.Copy(Path.Combine(source, file), Path.Combine(target, file));
            File.WriteAllText(Path.Combine(target, "theme.json"), JsonSerializer.Serialize(manifest, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase }));
            _ = new GifTheme(target);
            return name;
        }
        catch { Directory.Delete(target, true); throw; }
    }
}
