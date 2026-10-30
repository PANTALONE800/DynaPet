using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text;
using System.Text.RegularExpressions;

namespace DynaPet.Core;

public sealed record ThemeManifest([property: JsonPropertyName("format")] string Format, [property: JsonPropertyName("version")] int Version, [property: JsonPropertyName("name")] string Name, [property: JsonPropertyName("states")] Dictionary<string, string> States)
{
    public static ThemeManifest Read(string directory)
    {
        var path = Path.Combine(directory, "theme.json");
        if (new FileInfo(path).Length > 65536) throw new InvalidDataException("theme.json 超过 64 KiB。");
        var theme = JsonSerializer.Deserialize<ThemeManifest>(File.ReadAllText(path))
            ?? throw new InvalidDataException("无效 theme.json。");
        string[] allowed = ["idle", "touch", "sleep", "welcome", "focus", "happy", "hot", "dizzy", "puzzled", "low", "message"];
        if (theme.Format != "dynapet-theme" || theme.Version != 1 || string.IsNullOrEmpty(theme.Name) || Encoding.UTF8.GetByteCount(theme.Name) > 128 || theme.States == null ||
            new[] { "idle", "touch", "sleep" }.Any(k => !theme.States.ContainsKey(k)) || theme.States.Keys.Any(k => !allowed.Contains(k)))
            throw new InvalidDataException("不支持的动态主题配置。");
        foreach (var filename in theme.States.Values)
        {
            if (filename == null || !Regex.IsMatch(filename, @"\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\.gif\z")) throw new InvalidDataException("GIF 文件名只能使用英文、数字、下划线和连字符。");
            var file = new FileInfo(Path.Combine(directory, filename));
            if (!file.Exists || (file.Attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0 || file.Length > 32 * 1024 * 1024)
                throw new InvalidDataException("GIF 必须是小于 32 MiB 的普通文件。");
        }
        return theme;
    }
    public string FileFor(Mood mood)
    {
        var key = mood == Mood.Shy ? "touch" : mood == Mood.Sleepy ? "sleep" : mood.ToString().ToLowerInvariant();
        return States.TryGetValue(key, out var file) ? file : States["idle"];
    }
}

public sealed class GifTimeline
{
    public double[] Delays { get; }
    public int? Repeats { get; }
    public double Duration { get; }
    public GifTimeline(double[] delays, int? repeats)
    {
        if (delays.Length == 0 || delays.Any(d => !double.IsFinite(d) || d <= 0) || repeats < 0) throw new ArgumentException("Invalid GIF timing");
        Delays = delays; Repeats = repeats; Duration = delays.Sum();
    }
    public int Index(double elapsed)
    {
        elapsed = Math.Max(0, elapsed);
        if (Repeats != 0 && elapsed >= Duration * ((Repeats ?? 0) + 1)) return Delays.Length - 1;
        var phase = elapsed % Duration;
        double boundary = 0;
        for (var i = 0; i < Delays.Length; i++) { boundary += Delays[i]; if (phase < boundary) return i; }
        return Delays.Length - 1;
    }
}
