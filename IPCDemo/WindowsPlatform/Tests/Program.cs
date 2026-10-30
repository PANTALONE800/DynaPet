using DynaPet.Core;

var checks = 0;
void Check(bool condition, string label)
{
    if (!condition) throw new Exception("FAIL: " + label);
    checks++;
}
void MoodIs(Snapshot s, Mood mood, string label, bool greeting = false) => Check(Rules.Decide(s, greeting).Mood == mood, label);
MoodIs(new(Battery: 1, Cpu: 100), Mood.Welcome, "welcome precedes all", true);
MoodIs(new(Battery: 15, Cpu: 100), Mood.Low, "battery 15 priority");
MoodIs(new(Battery: 16), Mood.Idle, "battery 16 not low");
MoodIs(new(Battery: null), Mood.Idle, "unknown battery is not 0");
MoodIs(new(Battery: 1, Charging: true), Mood.Happy, "external power overrides low battery");
MoodIs(new(Idle: 265, ScreenTimeout: 300, Cpu: 100), Mood.Sleepy, "display threshold inclusive");
MoodIs(new(Idle: 264, ScreenTimeout: 300, Cpu: 100), Mood.Dizzy, "before display threshold");
MoodIs(new(Idle: 60, ScreenTimeout: 90), Mood.Idle, "idle must exceed 60");
MoodIs(new(Idle: 61, ScreenTimeout: 90), Mood.Sleepy, "minimum display threshold");
MoodIs(new(Cpu: 83), Mood.Hot, "CPU 83");
MoodIs(new(Cpu: 83.001), Mood.Dizzy, "CPU above 83");
MoodIs(new(Cpu: 55), Mood.Idle, "CPU 55");
MoodIs(new(Cpu: 55.001), Mood.Hot, "CPU above 55");
MoodIs(new(Windows: 24), Mood.Idle, "window 24");
MoodIs(new(Windows: 25), Mood.Hot, "window 25");
MoodIs(new(Apps: 22), Mood.Idle, "apps 22");
MoodIs(new(Apps: 23), Mood.Hot, "apps 23");
MoodIs(new(Awake: 3000), Mood.Idle, "3000 seconds boundary");
MoodIs(new(Awake: 3001), Mood.Sleepy, "long session");
MoodIs(new(Awake: 3001, Idle: 60), Mood.Idle, "long session idle boundary");
MoodIs(new(Idle: 180), Mood.Idle, "idle 180");
MoodIs(new(Idle: 181), Mood.Sleepy, "idle over 180");
foreach (var name in new[] { "Code", "WindowsTerminal", "devenv", "powershell", "cmd", "终端", "wps", "WINWORD", "EXCEL", "POWERPNT" })
    MoodIs(new(Front: name), Mood.Focus, "Windows application mapping " + name);
MoodIs(new(Front: "explorer"), Mood.Puzzled, "Explorer mapping");
MoodIs(new(Front: "文件资源管理器"), Mood.Puzzled, "localized Explorer mapping");
MoodIs(new(Charging: true, Front: "Code"), Mood.Focus, "front app before power happiness");

var state = new PetState(100);
state.Update(new(Battery: 10), 113.999); Check(state.Mood == Mood.Welcome, "14-second welcome hold");
state.Update(new(Battery: 10), 114); Check(state.Mood == Mood.Low, "welcome ends exactly at 14 seconds");
state.Touch(120); Check(state.Mood == Mood.Shy && state.Forced == null, "touch uses original shy pose");
state.Update(new(Cpu: 100), 126.999); Check(state.Mood == Mood.Shy, "7-second touch holds against high CPU");
state.Update(new(Cpu: 100), 127); Check(state.Mood == Mood.Shy, "9-second hysteresis may extend touch");
state.Update(new(Cpu: 100), 129); Check(state.Mood == Mood.Shy, "switch requires strictly more than 9 seconds");
state.Update(new(Cpu: 100), 129.001); Check(state.Mood == Mood.Dizzy, "switch after 9 seconds");
var changed = state.ChangedAt; var started = state.AnimationStartedAt;
state.Update(new(Cpu: 99), 130); Check(state.ChangedAt == changed && state.AnimationStartedAt == started, "same mood does not replay or reset hysteresis");
state.Touch(140); state.Touch(145);
Check(state.AnimationStartedAt == 145 && state.ChangedAt == 140, "repeat touch replays but does not reset mood change timestamp");
state.Update(new(Battery: 1), 151.999); Check(state.Mood == Mood.Shy, "repeat touch refreshes 7-second hold");
state.Update(new(Battery: 1), 152); Check(state.Mood == Mood.Low, "low battery takes priority after touch hold");
state.Preview(Mood.Happy, 160); Check(state.Mood == Mood.Happy, "manual preview");
state.Update(new(Cpu: 100), 170); Check(state.Mood == Mood.Happy, "preview survives environment changes");
state.Touch(180); Check(state.Forced == null && state.Mood == Mood.Shy, "touch clears preview");
state.Preview(Mood.Puzzled, 181); Check(state.Mood == Mood.Shy, "preview respects current touch hold");
state.Update(new(), 187); Check(state.Mood == Mood.Puzzled, "pending manual preview after hold");
state.Preview(null, 200); state.Update(new(), 200); Check(state.Mood == Mood.Idle, "automatic mood restored");
state.Sleep(210); state.Update(new(Cpu: 100), 230); state.Touch(231);
Check(state.Sleeping && state.Mood == Mood.Sleepy, "sleep suspends environment and touch");
state.Preview(Mood.Dizzy, 232); Check(state.Mood == Mood.Sleepy, "sleep suspends manual preview");
state.Wake(240); Check(!state.Sleeping && state.Mood == Mood.Welcome && state.Forced == null, "wake resets preview and touch");
state.Update(new(Battery: 10), 253.999); Check(state.Mood == Mood.Welcome, "wake 14-second hold");
state.Update(new(Battery: 10), 254); Check(state.Mood == Mood.Low, "wake greeting ends at boundary");
Check(Enum.GetValues<Mood>().Length == 11, "all 11 poses retained, including legacy message asset as surprise preview");
foreach (var mood in Enum.GetValues<Mood>())
{
    var (duration, period) = mood.Timing();
    for (int i = 0; i < 6; i++) Check(mood.Frame(duration * (i + .5) / 6) == new[] { 0, 1, 2, 2, 1, 0 }[i], mood + " action frame " + i);
    Check(mood.Frame(duration + .01) == 0, mood + " rests after action");
    Check(mood.Frame(period + duration / 4) == 1, mood + " cycle repeats");
}
Console.WriteLine($"PASS: {checks} Windows C# behavior checks (7/9/14 timing, sleep/wake, priorities, manual preview, 11 animations). No messaging subsystem.");

// Exercise the exact OCR response protocol independently of any Windows console or OCR engine.
async Task<OcrResult> RoundTrip(OcrResult value)
{
    var name = OcrChannel.NewName();
    using var server = OcrChannel.Create(name);
    using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
    var receive = OcrChannel.Receive(server, deadline.Token);
    var send = OcrChannel.Send(name, value, deadline.Token);
    await send;
    return await receive;
}
var chinese = new OcrResult(true, "第一行：识别中文\nSecond line 😀\n" + new string('字', 5000), "");
Check(await RoundTrip(chinese) == chinese, "OCR channel preserves long Chinese, newlines and surrogate pairs");
var unavailable = new OcrResult(false, "", "未安装 OCR 语言包");
Check(await RoundTrip(unavailable) == unavailable, "OCR channel preserves specific failure reason");
var pipeName = OcrChannel.NewName();
using (var server = OcrChannel.Create(pipeName))
using (var cancel = new CancellationTokenSource(TimeSpan.FromMilliseconds(100)))
{
    try { await OcrChannel.Receive(server, cancel.Token); Check(false, "OCR connection must time out"); }
    catch (OperationCanceledException) { Check(true, "OCR channel cancellation before connect"); }
}
pipeName = OcrChannel.NewName();
using (var server = OcrChannel.Create(pipeName))
using (var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5)))
{
    var receive = OcrChannel.Receive(server, deadline.Token);
    using (var client = new System.IO.Pipes.NamedPipeClientStream(".", pipeName, System.IO.Pipes.PipeDirection.Out))
    { await client.ConnectAsync(deadline.Token); }
    try { await receive; Check(false, "empty OCR response must fail"); }
    catch (InvalidDataException) { Check(true, "empty OCR response is a transport error, not no-text success"); }
}
pipeName = OcrChannel.NewName();
using (var server = OcrChannel.Create(pipeName))
using (var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5)))
{
    var receive = OcrChannel.Receive(server, deadline.Token);
    var send = Task.Run(async () =>
    {
        using var client = new System.IO.Pipes.NamedPipeClientStream(".", pipeName, System.IO.Pipes.PipeDirection.Out);
        await client.ConnectAsync(deadline.Token);
        try { await client.WriteAsync(new byte[100000], deadline.Token); }
        catch (IOException) { }
    });
    try { await receive; Check(false, "oversized OCR response must fail"); }
    catch (InvalidDataException) { Check(true, "OCR response size is bounded"); }
    await send;
}
var timeline = new GifTimeline([.04, .08, .12, .16, .20, .24, .28, .32], 0);
Check(timeline.Index(0) == 0 && timeline.Index(.041) == 1, "GIF variable delays");
Check(timeline.Index(.7) == 5, "GIF frames beyond first three");
Check(timeline.Index(timeline.Duration * 100 + .001) == 0, "GIF infinite looping");
Check(new GifTimeline([.1, .2], null).Index(100) == 1, "GIF absent loop freezes last");
var finite = new GifTimeline([.1, .2], 2);
Check(finite.Index(.601) == 0 && finite.Index(.901) == 1, "GIF repeats after first pass and freezes last");
var themeDirectory = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../../../../TestThemes/MinimalGif"));
// Optional explicit root makes these platform-independent contract tests usable in CI.
if (args.Length == 1) themeDirectory = Path.Combine(Path.GetFullPath(args[0]), "TestThemes", "MinimalGif");
if (Directory.Exists(themeDirectory))
{
    var manifest = ThemeManifest.Read(themeDirectory);
    foreach (var mood in Enum.GetValues<Mood>()) Check(manifest.FileFor(mood) == "demo.gif", "shared theme fallback " + mood);
}
if (args.Length == 1)
{
    var root = Path.GetFullPath(args[0]);
    using var expected = System.Text.Json.JsonDocument.Parse(File.ReadAllText(Path.Combine(root, "TestThemes/Conformance/expected.json")));
    var distinct = ThemeManifest.Read(Path.Combine(root, "TestThemes/Conformance"));
    Check(distinct.FileFor(Mood.Shy) == "finite.gif" && distinct.FileFor(Mood.Sleepy) == "disposal.gif" && distinct.FileFor(Mood.Focus) == "zero-delay.gif", "distinct shared states");
    var temporary = Directory.CreateTempSubdirectory("gif-negative-");
    try
    {
        var bad = Path.Combine(temporary.FullName, "bad.gif");
        File.WriteAllBytes(bad, File.ReadAllBytes(Path.Combine(root, "TestThemes/MinimalGif/demo.gif"))[..^100]);
        try { GifMetadata.Read(bad); Check(false, "truncated GIF rejected"); } catch (InvalidDataException) { Check(true, "truncated GIF rejected"); }
        File.WriteAllText(Path.Combine(temporary.FullName, "theme.json"), "{\"format\":\"dynapet-theme\",\"version\":1,\"name\":\"bad\",\"states\":{\"idle\":\"../demo.gif\",\"touch\":\"demo.gif\",\"sleep\":\"demo.gif\"}}");
        try { ThemeManifest.Read(temporary.FullName); Check(false, "path traversal rejected"); } catch (InvalidDataException) { Check(true, "path traversal rejected"); }
    }
    finally { temporary.Delete(true); }
    foreach (var entry in expected.RootElement.EnumerateObject())
    {
        var file = Path.Combine(root, "TestThemes", entry.Name == "demo.gif" ? "MinimalGif" : "Conformance", entry.Name);
        var gif = GifMetadata.Read(file); var frames = entry.Value.GetProperty("frames").EnumerateArray().ToArray();
        var loop = entry.Value.GetProperty("repeats");
        Check(gif.Repeats == (loop.ValueKind == System.Text.Json.JsonValueKind.Null ? (int?)null : loop.GetInt32()), "raw GIF repeat " + entry.Name);
        Check(gif.Delays.Length == frames.Length && gif.Delays.Length > 3, "all GIF frame metadata " + entry.Name);
        for (var j = 0; j < frames.Length; j++) Check(Math.Abs(gif.Delays[j] - frames[j].GetProperty("delay").GetDouble()) < .000001, "GIF delay " + entry.Name);
    }
}
Console.WriteLine($"PASS: {checks} total behavior and OCR transport checks.");
