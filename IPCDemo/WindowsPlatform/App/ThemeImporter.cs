using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using DynaPet.Core;

namespace DynaPet.Windows;

internal static class ThemeImporter
{
    internal static string Root => Path.Combine(Settings.DirectoryPath, "Themes");
    internal static readonly string[] Extensions = [".png", ".jpg", ".jpeg", ".bmp", ".gif"];
    internal static bool Accepts(string path) => Directory.Exists(path) || File.Exists(path) && Extensions.Contains(Path.GetExtension(path).ToLowerInvariant());
    internal static string? Resolve(string? name) => name != null && name.StartsWith("theme-", StringComparison.Ordinal) &&
        Path.GetFileName(name) == name && Directory.Exists(Path.Combine(Root, name)) ? Path.Combine(Root, name) : null;
    internal static string Import(string[] paths, string? destinationRoot = null)
    {
        if (paths.Length == 1 && Directory.Exists(paths[0]))
        {
            var directory = paths[0];
            if (File.Exists(Path.Combine(directory, "theme.json"))) return ImportPrepared(directory, destinationRoot);
            paths = Directory.EnumerateFiles(directory).Where(p => File.Exists(p) && Extensions.Contains(Path.GetExtension(p).ToLowerInvariant())).Take(12).ToArray();
        }
        if (paths.Any(p => Path.GetExtension(p).Equals(".gif", StringComparison.OrdinalIgnoreCase)))
        {
            if (paths.Length != 1) throw new InvalidDataException("多份 GIF 请通过 theme.json 映射后导入主题包，避免丢失动画。");
            var source = new FileInfo(paths[0]);
            if (!source.Exists || (source.Attributes & FileAttributes.ReparsePoint) != 0 || source.Length > 32 * 1024 * 1024) throw new InvalidDataException("GIF 必须是小于 32 MiB 的普通文件。");
            var staging = Directory.CreateTempSubdirectory("dynapet-gif-");
            try
            {
                File.Copy(paths[0], Path.Combine(staging.FullName, "animation.gif"));
                var states = new Dictionary<string, string> { ["idle"] = "animation.gif", ["touch"] = "animation.gif", ["sleep"] = "animation.gif" };
                File.WriteAllText(Path.Combine(staging.FullName, "theme.json"), JsonSerializer.Serialize(new ThemeManifest("dynapet-theme", 1, "Imported GIF", states)));
                return GifTheme.Import(staging.FullName, destinationRoot ?? Root);
            }
            finally { staging.Delete(true); }
        }
        if (paths.Length is < 1 or > 11 || paths.Any(p => !Accepts(p))) throw new InvalidDataException("请选择 1～11 张 PNG、JPEG、BMP 或 GIF 图片。");
        var images = new Dictionary<string, BitmapSource[]>();
        foreach (var path in paths)
        {
            if (new FileInfo(path).Length > 32 * 1024 * 1024) throw new InvalidDataException("单张图片请小于 32 MB。");
            using var stream = File.OpenRead(path);
            var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.DelayCreation, BitmapCacheOption.OnLoad);
            var first = decoder.Frames[0];
            if (first.PixelWidth < 1 || first.PixelHeight < 1 || (long)first.PixelWidth * first.PixelHeight > 32_000_000)
                throw new InvalidDataException("图片尺寸过大，请使用不超过 3200 万像素的图片。");
            var frames = decoder.Frames.Take(1).Select(frame =>
            {
                var ratio = Math.Min(224.0 / frame.PixelWidth, 224.0 / frame.PixelHeight);
                var width = frame.PixelWidth * ratio; var height = frame.PixelHeight * ratio;
                var visual = new DrawingVisual();
                using (var draw = visual.RenderOpen()) draw.DrawImage(frame, new Rect((256 - width) / 2, (256 - height) / 2, width, height));
                var normalized = new RenderTargetBitmap(256, 256, 96, 96, PixelFormats.Pbgra32);
                normalized.Render(visual); normalized.Freeze(); return (BitmapSource)normalized;
            }).ToArray();
            images[Path.GetFileNameWithoutExtension(path).ToLowerInvariant()] = frames;
        }
        var fallback = images.TryGetValue("idle", out var idle) ? idle : images.Values.First();
        var folder = "theme-" + Guid.NewGuid().ToString("N");
        var destination = Path.Combine(destinationRoot ?? Root, folder);
        Directory.CreateDirectory(destination);
        foreach (var mood in Enum.GetValues<Mood>())
        {
            var key = mood.ToString().ToLowerInvariant();
            var frames = images.TryGetValue(key, out var supplied) ? supplied : fallback;
            var visual = new DrawingVisual();
            using (var context = visual.RenderOpen())
                for (var i = 0; i < 3; i++)
                {
                    var frame = frames[i % frames.Length];
                    var ratio = Math.Min(224.0 / frame.PixelWidth, 224.0 / frame.PixelHeight);
                    var width = frame.PixelWidth * ratio; var height = frame.PixelHeight * ratio;
                    context.DrawImage(frame, new Rect(i * 256 + (256 - width) / 2, (256 - height) / 2, width, height));
                }
            var bitmap = new RenderTargetBitmap(768, 256, 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(visual);
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using var output = File.Create(Path.Combine(destination, key + ".png")); encoder.Save(output);
        }
        File.WriteAllText(Path.Combine(destination, "theme.json"), JsonSerializer.Serialize(new
        { version = 1, layout = "three-frame-strip", moods = Enum.GetNames<Mood>().Select(n => n.ToLowerInvariant()), rights = "User-provided images; original rights retained" }));
        // Validate all outputs before changing the selected theme. Existing themes stay untouched.
        _ = new Sprites(destination);
        return folder;
    }
    private static string ImportPrepared(string source, string? destinationRoot)
    {
        var metadata = new FileInfo(Path.Combine(source, "theme.json"));
        if (metadata.Length > 65536) throw new InvalidDataException("主题描述文件过大。");
        using var manifest = JsonDocument.Parse(File.ReadAllText(metadata.FullName));
        if (manifest.RootElement.TryGetProperty("format", out var format) && format.GetString() == "dynapet-theme") return GifTheme.Import(source, destinationRoot ?? Root);
        if (manifest.RootElement.GetProperty("version").GetInt32() != 1 || manifest.RootElement.GetProperty("layout").GetString() != "three-frame-strip")
            throw new InvalidDataException("不支持的主题格式。");
        foreach (var mood in Enum.GetValues<Mood>())
        {
            var file = Path.Combine(source, mood.ToString().ToLowerInvariant() + ".png");
            if (new FileInfo(file).Length > 32 * 1024 * 1024) throw new InvalidDataException("主题图片过大。");
            using var stream = File.OpenRead(file);
            var frame = BitmapDecoder.Create(stream, BitmapCreateOptions.DelayCreation, BitmapCacheOption.None).Frames[0];
            if (frame.PixelWidth != 768 || frame.PixelHeight != 256) throw new InvalidDataException("主题图片应为 768×256 横向三帧。");
        }
        _ = new Sprites(source);
        var name = "theme-" + Guid.NewGuid().ToString("N");
        var target = Path.Combine(destinationRoot ?? Root, name); Directory.CreateDirectory(target);
        foreach (var mood in Enum.GetValues<Mood>())
        {
            var file = mood.ToString().ToLowerInvariant() + ".png"; File.Copy(Path.Combine(source, file), Path.Combine(target, file));
        }
        File.WriteAllText(Path.Combine(target, "theme.json"), JsonSerializer.Serialize(new { version = 1, layout = "three-frame-strip", rights = "User-provided images; original rights retained" }));
        return name;
    }
}
