using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using DynaPet.Core;

namespace DynaPet.Windows;

internal static class GifThemeChecks
{
    // Runs the actual Windows native decoder without opening a pet window.
    internal static int Run(string repository, string report)
    {
        var lines = new List<string>();
        void Check(bool ok, string text) { if (!ok) throw new InvalidDataException(text); }
        try
        {
            var fixtures = Path.Combine(repository, "TestThemes", "Conformance");
            var theme = Path.Combine(repository, "TestThemes", "MinimalGif");
            using var expected = JsonDocument.Parse(File.ReadAllText(Path.Combine(fixtures, "expected.json")));
            foreach (var file in expected.RootElement.EnumerateObject())
            {
                long budget = 64_000_000;
                var clip = GifClip.Load(Path.Combine(file.Name == "demo.gif" ? theme : fixtures, file.Name), ref budget);
                var frames = file.Value.GetProperty("frames").EnumerateArray().ToArray();
                Check(clip.Frames.Length == frames.Length && frames.Length > 3, "all frames: " + file.Name);
                var loops = file.Value.GetProperty("repeats");
                int? repeats = loops.ValueKind == JsonValueKind.Null ? null : loops.GetInt32();
                Check(clip.Timeline.Repeats == repeats, "repeat metadata: " + file.Name);
                for (var i = 0; i < frames.Length; i++)
                {
                    Check(Math.Abs(clip.Timeline.Delays[i] - frames[i].GetProperty("delay").GetDouble()) < .000001, "delay: " + file.Name + "/" + i);
                    Check(Hash(clip.Frames[i]) == frames[i].GetProperty("rgbaFNV1a").GetString(), "compositing: " + file.Name + "/" + i);
                }
                Check(clip.Timeline.Index(0) == 0, "starts first");
                if (repeats == 0) Check(clip.Timeline.Index(clip.Timeline.Duration * 100 + .001) == 0, "infinite loop");
                else Check(clip.Timeline.Index(clip.Timeline.Duration * ((repeats ?? 0) + 1) + .001) == frames.Length - 1, "finite freeze last");
                lines.Add("PASS: " + file.Name + ": all frames, delays, repeats, composited RGBA");
            }
            var distinct = new GifTheme(fixtures);
            Check(distinct.Clip(Mood.Shy).Timeline.Repeats == 2, "touch selects finite.gif");
            Check(distinct.Clip(Mood.Sleepy).Timeline.Repeats == 0, "sleep selects disposal.gif");
            Check(distinct.Clip(Mood.Idle).Timeline.Repeats == null, "idle selects once.gif");
            Check(distinct.Clip(Mood.Focus).Timeline.Delays[1] == .01, "optional mood selects distinct GIF");
            var temporary = Directory.CreateTempSubdirectory("dynapet-gif-check-");
            try
            {
                var imported = ThemeImporter.Import([theme], temporary.FullName);
                var loaded = new Sprites(Path.Combine(temporary.FullName, imported));
                Check(loaded.Count == 11, "mapped all 11 moods");
                foreach (var mood in Enum.GetValues<Mood>()) Check(loaded.Index(mood, .041) == 1, "mapped GIF timeline");
                Check(loaded.Index(Mood.Idle, .7) > 3, "not truncated");
                var single = ThemeImporter.Import([Path.Combine(theme, "demo.gif")], temporary.FullName);
                var singleSprites = new Sprites(Path.Combine(temporary.FullName, single));
                Check(singleSprites.Index(Mood.Idle, .7) == 5, "single GIF import preserves all frames");
                lines.Add("PASS: native folder import and 11 state mappings; no GUI opened");
            }
            finally { temporary.Delete(true); }
            File.WriteAllLines(report, lines); return 0;
        }
        catch (Exception error) { lines.Add("FAIL: " + error); File.WriteAllLines(report, lines); return 1; }
    }
    private static string Hash(BitmapSource source)
    {
        var image = new FormatConvertedBitmap(source, PixelFormats.Bgra32, null, 0);
        var bytes = new byte[image.PixelWidth * image.PixelHeight * 4]; image.CopyPixels(bytes, image.PixelWidth * 4, 0);
        uint hash = 2166136261;
        for (var i = 0; i < bytes.Length; i += 4)
        {
            byte[] rgba = bytes[i + 3] == 0 ? [0, 0, 0, 0] : [bytes[i + 2], bytes[i + 1], bytes[i], bytes[i + 3]];
            foreach (var value in rgba) hash = unchecked((hash ^ value) * 16777619);
        }
        return hash.ToString("x8");
    }
}
