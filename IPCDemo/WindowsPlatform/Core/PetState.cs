namespace DynaPet.Core;

public enum Mood { Welcome, Idle, Focus, Happy, Hot, Dizzy, Puzzled, Sleepy, Low, Shy, Message }
public sealed record Snapshot(double Cpu = 0, int? Battery = null, bool Charging = false,
    int Apps = 0, int? Windows = null, int? Folders = null, int? Documents = null,
    string Front = "桌面", double Idle = 0, double Awake = 0, double ScreenTimeout = 0);
public sealed record Decision(Mood Mood, string Text);

public static class Rules
{
    public static Decision Decide(Snapshot s, bool greeting)
    {
        if (greeting) return new(Mood.Welcome, "你回来啦！今天也一起加油～");
        if (s.Battery is <= 15 && !s.Charging) return new(Mood.Low, $"只剩 {s.Battery}% 电啦，给电脑充充电吧。");
        if (s.Idle > 60 && s.ScreenTimeout > 0 && s.Idle >= Math.Max(60, s.ScreenTimeout - 35))
            return new(Mood.Sleepy, "闲置了一会儿，屏幕可能快休息啦…");
        if (s.Cpu > 83) return new(Mood.Dizzy, $"CPU {(int)s.Cpu}%，电脑忙晕啦…");
        if (s.Cpu > 55 || s.Windows > 24 || s.Apps > 22) return new(Mood.Hot, $"{s.Apps} 个软件在运行，慢慢来，我陪你。");
        if (s.Awake > 3000 && s.Idle < 60) return new(Mood.Sleepy, $"连续用电脑快 {(int)(s.Awake / 60)} 分钟啦，伸个懒腰？");
        if (s.Idle > 180) return new(Mood.Sleepy, "我在这里等你… zZ");
        var n = s.Front.ToLowerInvariant();
        if (new[] { "code", "terminal", "devenv", "powershell", "cmd", "终端" }.Any(n.Contains))
            return new(Mood.Focus, $"在 {s.Front} 写代码呀，我安静陪你。");
        if (new[] { "wps", "word", "excel", "powerpoint", "winword", "powerpnt" }.Any(n.Contains))
            return new(Mood.Focus, "文档时间！和你一起认真工作。");
        if (n.Contains("explorer") || n.Contains("文件资源管理器")) return new(Mood.Puzzled, "找文件吗？整理好就不会迷路啦。");
        if (s.Charging) return new(Mood.Happy, "正在补充能量！我也精神起来啦。");
        return new(Mood.Idle, $"你用 {s.Front}，我在旁边陪你。");
    }
    public static string Title(this Mood m) => m switch
    {
        Mood.Welcome => "欢迎回来", Mood.Idle => "陪着你", Mood.Focus => "专注中", Mood.Happy => "好耶",
        Mood.Hot => "有点忙", Mood.Dizzy => "忙晕了", Mood.Puzzled => "在找什么呀", Mood.Sleepy => "困困",
        Mood.Low => "快没电啦", Mood.Shy => "被摸摸了", _ => "惊喜"
    };
    public static (double Duration, double Period) Timing(this Mood m) => m switch
    {
        Mood.Welcome => (.40, 3.8), Mood.Idle => (.30, 4.6), Mood.Focus => (1.15, 3.4),
        Mood.Happy => (.34, 3.9), Mood.Hot => (1.20, 2.7), Mood.Dizzy => (1.90, 2.0),
        Mood.Puzzled => (.34, 4.4), Mood.Sleepy => (2.20, 5.0), Mood.Low => (1.15, 3.1),
        Mood.Shy => (.85, 3.5), _ => (.32, 4.0)
    };
    public static int Frame(this Mood m, double elapsed)
    {
        var (duration, period) = m.Timing();
        var phase = (period - duration + Math.Max(0, elapsed)) % period;
        if (phase < period - duration) return 0;
        return new[] { 0, 1, 2, 2, 1, 0 }[Math.Clamp((int)((phase - period + duration) / duration * 6), 0, 5)];
    }
}

/// All calls are serialized by the owning UI dispatcher; time is injected for tests.
public sealed class PetState
{
    public Mood Mood { get; private set; } = Mood.Welcome;
    public string Text { get; private set; } = "你好呀，我是 DynaPet！";
    public Mood? Forced { get; private set; }
    public bool Sleeping { get; private set; }
    public double ChangedAt { get; private set; }
    public double AnimationStartedAt { get; private set; }
    private double welcomeUntil, holdUntil;
    public PetState(double now) { ChangedAt = AnimationStartedAt = now; welcomeUntil = now + 14; }
    private void Set(Mood mood, string text, double now, bool replay = false)
    {
        if (Mood != mood) ChangedAt = now;
        if (Mood != mood || replay) AnimationStartedAt = now;
        Mood = mood; Text = text;
    }
    public void Update(Snapshot s, double now)
    {
        if (Sleeping || now < holdUntil) return;
        if (Forced is { } forced) { Set(forced, $"动作预览 · {forced.Title()}", now); return; }
        var d = Rules.Decide(s, now < welcomeUntil);
        if (Mood == d.Mood || now - ChangedAt > 9 || d.Mood is Mood.Low or Mood.Welcome) Set(d.Mood, d.Text, now);
    }
    public void Touch(double now)
    {
        if (Sleeping) return;
        Forced = null; holdUntil = now + 7;
        Set(Mood.Shy, "嘿嘿，被你摸摸啦～", now, true);
    }
    public void Preview(Mood? mood, double now)
    {
        if (Sleeping) return;
        Forced = mood;
        if (now >= holdUntil && mood is { } value) Set(value, $"动作预览 · {value.Title()}", now, true);
    }
    public void Sleep(double now) { Sleeping = true; Set(Mood.Sleepy, "晚安，等你回来。", now); }
    public void Wake(double now)
    {
        Sleeping = false; Forced = null; holdUntil = 0; welcomeUntil = now + 14;
        Set(Mood.Welcome, "你回来啦！今天也一起加油～", now, true);
    }
}
