using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using DynaPet.Core;

namespace DynaPet.Windows;

internal sealed class Sprites
{
    private readonly Dictionary<Mood, BitmapSource[]> clips = new();
    private readonly GifTheme? theme;
    internal Sprites(string? directory = null)
    {
        if (directory != null && File.Exists(Path.Combine(directory, "theme.json")))
        {
            using var json = System.Text.Json.JsonDocument.Parse(File.ReadAllText(Path.Combine(directory, "theme.json")));
            if (json.RootElement.TryGetProperty("format", out var format) && format.GetString() == "dynapet-theme")
            {
                theme = new GifTheme(directory);
                foreach (var mood in Enum.GetValues<Mood>()) clips[mood] = theme.Clip(mood).Frames;
                return;
            }
        }
        // Embedded DemoTheme is the default data source; custom themes use a directory.
        foreach (var mood in Enum.GetValues<Mood>())
        {
            var path = "DynaPet.DemoTheme." + mood.ToString().ToLowerInvariant() + ".png";
            using var stream = directory == null ? Assembly.GetExecutingAssembly().GetManifestResourceStream(path)
                : File.OpenRead(Path.Combine(directory, mood.ToString().ToLowerInvariant() + ".png"));
            if (stream == null) throw new InvalidDataException("素材缺失：" + path);
            var image = new BitmapImage(); image.BeginInit(); image.StreamSource = stream;
            image.CacheOption = BitmapCacheOption.OnLoad; image.EndInit(); image.Freeze();
            if (image.PixelWidth % 3 != 0) throw new InvalidDataException("动作素材必须为横向三帧：" + path);
            var sheet = new FormatConvertedBitmap(image, PixelFormats.Bgra32, null, 0);
            var cell = sheet.PixelWidth / 3; var height = sheet.PixelHeight;
            var stride = sheet.PixelWidth * 4;
            var bytes = new byte[stride * height]; sheet.CopyPixels(bytes, stride, 0);
            var left = cell; var right = -1; var top = height; var bottom = -1;
            // One common alpha crop across three frames; no pose-to-pose size jumps.
            for (var y = 0; y < height; y++) for (var x = 0; x < sheet.PixelWidth; x++)
                if (bytes[y * stride + x * 4 + 3] > 180)
                { left = Math.Min(left, x % cell); right = Math.Max(right, x % cell); top = Math.Min(top, y); bottom = Math.Max(bottom, y); }
            if (right < left || bottom < top) throw new InvalidDataException("动作素材为空：" + path);
            var frames = Enumerable.Range(0, 3).Select(i => (BitmapSource)new CroppedBitmap(sheet,
                new Int32Rect(i * cell + left, top, right - left + 1, bottom - top + 1))).ToArray();
            foreach (var frame in frames) frame.Freeze();
            clips[mood] = frames;
        }
    }
    internal BitmapSource Frame(Mood mood, int index) => clips[mood][index];
    internal int Index(Mood mood, double elapsed) => theme?.Clip(mood).Timeline.Index(elapsed) ?? mood.Frame(elapsed);
    internal int Count => clips.Count;
}
