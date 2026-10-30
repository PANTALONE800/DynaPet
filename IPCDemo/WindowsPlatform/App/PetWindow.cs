using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Reflection;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;
using DynaPet.Core;
using Forms = System.Windows.Forms;

namespace DynaPet.Windows;

internal sealed class PetWindow : Window, IDisposable
{
    private readonly Settings settings = Settings.Load();
    private Sprites sprites = new();
    private readonly PetState state;
    private readonly Native.Sensors sensors = new();
    private readonly Forms.NotifyIcon tray;
    private readonly DispatcherTimer frames, samples;
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private readonly Image sprite = new() { Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly TextBlock caption = Text("你好呀，我是 DynaPet！", 12);
    private readonly TextBlock heading = Text("DynaPet · 本机感知", 13);
    private readonly TextBlock statistics = Text("正在读取系统状态…", 11);
    private readonly ProgressBar cpu = new() { Minimum = 0, Maximum = 100, Height = 5, Margin = new Thickness(0, 8, 0, 8) };
    private readonly TextBlock time = Text("", 11);
    private readonly TextBlock ocrStatus = Text("窗口文字识别：右键菜单中手动发起", 11);
    private readonly TextBlock login = Text("", 11);
    private readonly System.Threading.CancellationTokenSource lifetime = new();
    private readonly Border dashboard;
    private readonly ScrollViewer detailScroll;
    private readonly ScaleTransform breathing = new(1, 1);
    private readonly RotateTransform rocking = new();
    private Snapshot snapshot = new();
    private bool disposed, sampling, locked, suspended, displayOff;
    private int environmentGeneration;
    private IntPtr powerRegistration;
    private HwndSource? windowSource;
    private int lastFrame = -1;
    private double themeStartedAt;
    private bool recognizing;
    private IntPtr selectedWindow;
    private string selectedTitle = "";
    private Mood? lastMood;
    private double lastAnimationStarted = -1;
    private IntPtr handle;
    private double pausedAt, pausedDuration;
    private string lastCaption = "";
    private double Now => clock.Elapsed.TotalSeconds;

    internal PetWindow()
    {
        state = new PetState(Now);
        if (ThemeImporter.Resolve(settings.Theme) is { } theme)
        {
            try { sprites = new Sprites(theme); } catch { settings.Theme = null; }
        }
        Title = "DynaPet"; Width = 220; SizeToContent = SizeToContent.Height;
        WindowStyle = WindowStyle.None; AllowsTransparency = true; Background = Brushes.Transparent;
        ShowInTaskbar = false; ShowActivated = false; Topmost = true; ResizeMode = ResizeMode.NoResize;
        AutomationProperties.SetName(this, "DynaPet桌宠；右键打开操作菜单");
        AllowDrop = true;
        DragOver += (_, e) => { e.Effects = e.Data.GetData(DataFormats.FileDrop) is string[] files && files.Length is > 0 and <= 11 && files.All(ThemeImporter.Accepts) ? DragDropEffects.Copy : DragDropEffects.None; e.Handled = true; };
        Drop += (_, e) => { if (e.Data.GetData(DataFormats.FileDrop) is string[] files) ImportTheme(files); e.Handled = true; };
        var stack = new StackPanel { Margin = new Thickness(6) };
        var bubble = Card(caption); bubble.Padding = new Thickness(12, 8, 12, 8);
        stack.Children.Add(bubble);
        sprite.Margin = new Thickness(0, 2, 0, 0);
        sprite.RenderTransformOrigin = new Point(.5, 1);
        var transforms = new TransformGroup(); transforms.Children.Add(breathing); transforms.Children.Add(rocking);
        sprite.RenderTransform = transforms;
        AutomationProperties.SetName(sprite, "DynaPet，点击摸摸，拖动移动");
        sprite.MouseLeftButtonDown += DragOrTouch;
        stack.Children.Add(sprite);
        var detail = new StackPanel();
        detail.Children.Add(heading); detail.Children.Add(Text("DynaPet · 非商用", 11)); detail.Children.Add(cpu); detail.Children.Add(statistics);
        detail.Children.Add(Divider()); detail.Children.Add(time);
        detail.Children.Add(ocrStatus); detail.Children.Add(login);
        var help = Text("按系统状态自动切换心情；右键可预览全部动作。\n识别文字仅在主动选择后进行，不保存截图或识别正文。", 10);
        help.Foreground = Brushes.DimGray; detail.Children.Add(help);
        detailScroll = new ScrollViewer { Content = detail, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            MaxHeight = 300, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        dashboard = Card(detailScroll); dashboard.Margin = new Thickness(0, 6, 0, 0);
        stack.Children.Add(dashboard); Content = stack;
        ContextMenu = new ContextMenu();
        ContextMenuOpening += (_, _) => { SelectForeground(); FillMenu(ContextMenu); ContextMenu.Placement = PlacementMode.MousePoint; };
        using var iconStream = Assembly.GetExecutingAssembly().GetManifestResourceStream("DynaPet.Icon") ?? throw new InvalidDataException("内置图标缺失");
        using var icon = new System.Drawing.Icon(iconStream);
        tray = new Forms.NotifyIcon { Icon = (System.Drawing.Icon)icon.Clone(),
            Text = "DynaPet · 右键打开菜单", Visible = true };
        tray.MouseUp += (_, e) => Dispatcher.InvokeAsync(() =>
        {
            if (e.Button == Forms.MouseButtons.Right)
            {
                SelectForeground();
                var menu = new ContextMenu { Placement = PlacementMode.MousePoint };
                FillMenu(menu); menu.IsOpen = true;
            }
            else if (e.Button == Forms.MouseButtons.Left) ShowPet();
        });
        frames = new DispatcherTimer(TimeSpan.FromSeconds(1.0 / 30), DispatcherPriority.Render, (_, _) => Render(), Dispatcher);
        samples = new DispatcherTimer(TimeSpan.FromSeconds(3), DispatcherPriority.Background, async (_, _) => await Sample(), Dispatcher);
        SourceInitialized += (_, _) =>
        {
            handle = new WindowInteropHelper(this).Handle;
            // Match the Mac nonactivating pet: clicking it does not replace the foreground app.
            var style = Native.GetWindowLongPtrW(handle, -20).ToInt64();
            Native.SetWindowLongPtrW(handle, -20, new IntPtr(style | 0x08000080));
            windowSource = HwndSource.FromHwnd(handle); windowSource?.AddHook(WindowMessage);
            var display = new Guid("6fe69556-704a-47a0-8f24-c28d936fda47");
            powerRegistration = Native.RegisterPowerSettingNotification(handle, ref display, 0);
            if (settings.Left is { } left && settings.Top is { } top) { Left = left; Top = top; }
        };
        Loaded += async (_, _) =>
        {
            ApplyLayout(); Place(settings.Left == null || settings.Top == null);
            await Sample();
        };
        SizeChanged += (_, _) => Dispatcher.InvokeAsync(() => { if (handle != IntPtr.Zero && IsLoaded) Place(false); });
        Closing += (_, _) => Dispose();
        SystemEvents.PowerModeChanged += PowerChanged;
        SystemEvents.SessionSwitch += SessionChanged;
        SystemEvents.DisplaySettingsChanged += DisplayChanged;
        ApplyLayout();
    }
    private static TextBlock Text(string text, double size) => new()
    {
        Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap,
        Foreground = new SolidColorBrush(Color.FromRgb(44, 52, 64)), Margin = new Thickness(0, 3, 0, 3)
    };
    private static Border Card(UIElement child) => new()
    {
        Background = new SolidColorBrush(Color.FromArgb(242, 250, 251, 253)), CornerRadius = new CornerRadius(14),
        BorderBrush = new SolidColorBrush(Color.FromArgb(90, 160, 170, 190)), BorderThickness = new Thickness(1),
        Padding = new Thickness(12), Child = child
    };
    private static Border Divider() => new() { Height = 1, Background = Brushes.LightGray, Margin = new Thickness(0, 8, 0, 8) };
    private void ApplyLayout()
    {
        var area = handle == IntPtr.Zero ? (Width: SystemParameters.WorkArea.Width, Height: SystemParameters.WorkArea.Height) : Native.WorkArea(handle);
        Width = Math.Min(area.Width, Math.Max(settings.Details ? 300 : 220, 220 * settings.Scale));
        sprite.Width = Math.Min(Width - 20, 200 * settings.Scale); sprite.Height = 160 * settings.Scale;
        dashboard.Visibility = settings.Details ? Visibility.Visible : Visibility.Collapsed;
        MaxHeight = area.Height;
        detailScroll.MaxHeight = Math.Max(80, Math.Min(300, MaxHeight - sprite.Height - 160));
        login.Text = "登录启动：" + (Settings.StartupEnabled ? "已开启（系统启动应用设置可管理）" : "关闭");
    }
    private void Place(bool reset) { if (handle != IntPtr.Zero) Native.Place(handle, reset); }
    internal void ShowPet() { if (disposed) return; Show(); Place(false); }
    private void DragOrTouch(object sender, MouseButtonEventArgs e)
    {
        var start = PointToScreen(e.GetPosition(this));
        try { DragMove(); } catch (InvalidOperationException) { }
        var end = PointToScreen(Mouse.GetPosition(this));
        if ((end - start).Length < 4) { state.Touch(Now); Render(); }
        else { ApplyLayout(); Place(false); Save(); }
        e.Handled = true;
    }
    private void Render()
    {
        if (disposed) return;
        if (lastAnimationStarted != state.AnimationStartedAt)
        {
            lastAnimationStarted = state.AnimationStartedAt;
            pausedDuration = 0;
            if (!settings.Animate) pausedAt = Now;
        }
        var animationTime = settings.Animate ? Now - pausedDuration : pausedAt - pausedDuration;
        var index = sprites.Index(state.Mood, Math.Max(0, animationTime - Math.Max(state.AnimationStartedAt, themeStartedAt)));
        if (lastMood != state.Mood || lastFrame != index)
        { sprite.Source = sprites.Frame(state.Mood, index); lastMood = state.Mood; lastFrame = index; }
        var t = settings.Animate ? Now : pausedAt;
        breathing.ScaleY = 1 + Math.Sin(t * 1.7) * .006;
        rocking.Angle = Math.Sin(t * (state.Mood == Mood.Dizzy ? 2 : 1.3)) * (state.Mood == Mood.Dizzy ? 1.8 : .45);
        if (lastCaption != state.Text) { caption.Text = state.Text; lastCaption = state.Text; }
        heading.Text = "DynaPet · " + state.Mood.Title();
    }
    private async System.Threading.Tasks.Task Sample()
    {
        if (sampling || disposed || state.Sleeping) return;
        sampling = true;
        var generation = environmentGeneration;
        SelectForeground();
        try
        {
            var value = await System.Threading.Tasks.Task.Run(sensors.Sample);
            if (disposed || state.Sleeping || generation != environmentGeneration) return;
            snapshot = value; state.Update(snapshot, Now); cpu.Value = snapshot.Cpu;
            statistics.Text = $"CPU {(int)snapshot.Cpu}% · 软件 {snapshot.Apps} · 本次 {(int)(snapshot.Awake / 60)} 分钟\n" +
                $"窗口 {snapshot.Windows} · 文件夹 {snapshot.Folders}\n可识别文档窗口 {snapshot.Documents}（按标题文件名估计，非全部标签页）\n前台：{snapshot.Front}\n" +
                $"电量：{(snapshot.Battery is { } b ? b + "%" : "未提供")} · {(snapshot.Charging ? "外接电源" : "未接外接电源")}";
            time.Text = $"本地时间：{DateTime.Now:yyyy-MM-dd HH:mm}\n闲置：{(int)snapshot.Idle} 秒\n连续使用：{(int)(snapshot.Awake / 60)} 分钟\n屏幕休息阈值：{(snapshot.ScreenTimeout > 0 ? (snapshot.ScreenTimeout / 60).ToString("0.#") + " 分钟" : "未启用或未提供")}";
            Render();
        }
        catch { statistics.Text = "本次系统状态读取失败，稍后重试"; }
        finally { sampling = false; }
    }
    private void SelectForeground()
    {
        var candidate = Native.GetForegroundWindow();
        if (candidate != IntPtr.Zero && Native.Owner(candidate) != Environment.ProcessId &&
            Native.ClassName(candidate) is not ("Shell_TrayWnd" or "Shell_SecondaryTrayWnd" or "Progman" or "WorkerW") &&
            Native.Title(candidate).Length > 0)
        { selectedWindow = candidate; selectedTitle = Native.Title(candidate); }
    }
    private async void Recognize()
    {
        if (recognizing || selectedWindow == IntPtr.Zero) return;
        var target = selectedWindow;
        if (MessageBox.Show($"仅识别这个窗口的可获取画面：\n{selectedTitle}\n\n在本机处理，不保存截图或识别正文。是否继续？", "窗口文字识别", MessageBoxButton.YesNo) != MessageBoxResult.Yes) return;
        recognizing = true; ocrStatus.Text = "窗口文字识别：识别中…";
        settings.Details = true; ApplyLayout(); ShowPet();
        try
        {
            var result = await OcrHost.Read(target, lifetime.Token);
            if (disposed) return;
            ocrStatus.Text = result.Ok ? "窗口文字识别：本次完成" : result.Error;
            if (result.Ok)
            {
                var text = new TextBox { Text = result.Text, IsReadOnly = true, TextWrapping = TextWrapping.Wrap,
                    VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Margin = new Thickness(16) };
                var resultWindow = new Window { Title = "本次窗口文字识别 · 不保存", Width = 540, Height = 360,
                    Content = text, Owner = this, ShowInTaskbar = false };
                resultWindow.Show();
            }
        }
        catch (Exception error)
        {
            if (!disposed) ocrStatus.Text = $"识别无法启动（{error.GetType().Name}，0x{error.HResult:X8}），桌宠可继续使用。";
        }
        finally { recognizing = false; }
    }
    private void FillMenu(ContextMenu menu)
    {
        menu.Items.Clear();
        menu.Items.Add(new MenuItem { Header = "DynaPet · 非商用", IsEnabled = false });
        menu.Items.Add(new Separator());
        MenuItem Add(string title, Action action, ItemsControl? parent = null, bool? check = null)
        {
            var item = new MenuItem { Header = title };
            if (check is { } value) { item.IsCheckable = true; item.IsChecked = value; }
            item.Click += (_, _) => { try { action(); } catch { MessageBox.Show("操作未完成，请检查当前用户权限或安装路径。", "DynaPet"); } };
            (parent ?? menu).Items.Add(item); return item;
        }
        Add(IsVisible ? "隐藏桌宠" : "显示桌宠", () => { if (IsVisible) Hide(); else ShowPet(); });
        Add(settings.Details ? "收起状态面板" : "展开状态面板", () => { settings.Details = !settings.Details; ApplyLayout(); ShowPet(); Save(); });
        Add("摸摸", () => { state.Touch(Now); Render(); });
        var moods = new MenuItem { Header = "动作预览" }; menu.Items.Add(moods);
        Add("自动感知", () => { state.Preview(null, Now); state.Update(snapshot, Now); Render(); }, moods, state.Forced == null);
        foreach (var mood in Enum.GetValues<Mood>())
            Add(mood.Title(), () => { state.Preview(mood, Now); Render(); }, moods, state.Forced == mood);
        Add(settings.Animate ? "暂停动作" : "恢复动作", () =>
        {
            if (settings.Animate) pausedAt = Now;
            else pausedDuration += Now - pausedAt;
            settings.Animate = !settings.Animate; Save(); Render();
        });
        var sizes = new MenuItem { Header = "大小" }; menu.Items.Add(sizes);
        foreach (var scale in new[] { .75, 1.0, 1.25 })
            Add($"{(int)(scale * 100)}%", () => { settings.Scale = scale; ApplyLayout(); Save(); }, sizes, settings.Scale == scale);
        Add("导入角色图片…", () =>
        {
            using var dialog = new Forms.OpenFileDialog { Title = "选择 1～11 张角色图；单图复用全部心情，命名 idle/happy 等可分别指定", Multiselect = true, Filter = "角色图片|*.png;*.jpg;*.jpeg;*.bmp;*.gif" };
            if (dialog.ShowDialog() == Forms.DialogResult.OK) ImportTheme(dialog.FileNames);
        });
        Add("恢复内置角色", () => { settings.Theme = null; sprites = new Sprites(); lastMood = null; Save(); Render(); });
        Add("导入主题包…", () =>
        {
            using var dialog = new Forms.FolderBrowserDialog { Description = "选择图片文件夹或含 theme.json 的完整主题目录" };
            if (dialog.ShowDialog() == Forms.DialogResult.OK) ImportTheme([dialog.SelectedPath]);
        });
        Add("打开角色文件夹", () => { Directory.CreateDirectory(ThemeImporter.Root); Settings.Open(ThemeImporter.Root); });
        Add("关于 DynaPet 与许可", () => MessageBox.Show("DynaPet 是跨平台桌宠引擎。\n自有代码沿用 PolyForm Noncommercial 1.0.0 非商用许可。\n演示和用户主题的图片权利独立于引擎代码，详见 DemoTheme/NOTICE.md。", "DynaPet · 非商用源码公开"));
        menu.Items.Add(new Separator());
        var recognize = Add(recognizing ? "窗口文字识别中…" : "识别前台窗口文字（本机 OCR）", Recognize);
        recognize.IsEnabled = !recognizing && selectedWindow != IntPtr.Zero;
        Add("OCR 语言包设置", () => Settings.Open("ms-settings:regionlanguage"));
        Add("打开 Windows 隐私设置", () => Settings.Open("ms-settings:privacy"));
        Add("权限说明", () => MessageBox.Show("环境采样和桌宠交互不需要管理员权限。\n文字识别只在主动选择后捕获指定窗口，需要 Windows OCR 语言组件。\n隐藏、最小化、受保护或不同权限的窗口可能无法识别。", "权限说明"));
        Add(Settings.StartupEnabled ? "关闭登录时启动" : "开启登录时启动", () => { Settings.Startup(!Settings.StartupEnabled); ApplyLayout(); });
        Add("打开系统启动应用设置", () => Settings.Open("ms-settings:startupapps"));
        Add("查看使用说明", () => Settings.Open(Path.Combine(AppContext.BaseDirectory, "使用说明.txt")));
        menu.Items.Add(new Separator()); Add("退出 DynaPet", () => { Dispose(); Application.Current.Shutdown(); });
    }
    private void Save()
    {
        if (IsLoaded) { settings.Left = Left; settings.Top = Top; }
        try { settings.Save(); } catch { login.Text = "设置保存失败，请检查本地用户目录权限"; }
    }
    private void ImportTheme(string[] files)
    {
        try
        {
            var folder = ThemeImporter.Import(files);
            var loaded = new Sprites(ThemeImporter.Resolve(folder));
            settings.Theme = folder; sprites = loaded; themeStartedAt = Now; pausedDuration = 0; if (!settings.Animate) pausedAt = Now; lastMood = null; Save(); Render();
        }
        catch (Exception error) { MessageBox.Show("角色导入失败，原角色保持不变。\n" + error.Message, "导入角色"); }
    }
    private void SynchronizeSleep()
    {
        environmentGeneration++;
        if (suspended || locked || displayOff) { state.Sleep(Now); }
        else if (state.Sleeping) { sensors.Wake(); state.Wake(Now); _ = Sample(); }
        Render();
    }
    private IntPtr WindowMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message == 0x02E0) Dispatcher.InvokeAsync(() => { if (!disposed) { ApplyLayout(); Place(false); } });
        if (message == 0x0218 && wParam.ToInt32() == 0x8013 && lParam != IntPtr.Zero &&
            Marshal.PtrToStructure<Guid>(lParam) == new Guid("6fe69556-704a-47a0-8f24-c28d936fda47") &&
            Marshal.ReadInt32(lParam, 16) >= 4)
        {
            var off = Marshal.ReadInt32(lParam, 20) == 0;
            if (off != displayOff) { displayOff = off; SynchronizeSleep(); }
        }
        return IntPtr.Zero;
    }
    private void PowerChanged(object sender, PowerModeChangedEventArgs e) => Dispatcher.InvokeAsync(() =>
    {
        if (disposed) return;
        if (e.Mode == PowerModes.Suspend) suspended = true;
        else if (e.Mode == PowerModes.Resume) suspended = false;
        else return;
        SynchronizeSleep();
    });
    private void SessionChanged(object sender, SessionSwitchEventArgs e) => Dispatcher.InvokeAsync(() =>
    {
        if (disposed) return;
        if (e.Reason is SessionSwitchReason.SessionLock or SessionSwitchReason.SessionLogoff) locked = true;
        else if (e.Reason is SessionSwitchReason.SessionUnlock or SessionSwitchReason.SessionLogon) locked = false;
        else return;
        SynchronizeSleep();
    });
    private void DisplayChanged(object? sender, EventArgs e) => Dispatcher.InvokeAsync(() => { if (!disposed) { ApplyLayout(); Place(false); } });
    public void Dispose()
    {
        if (disposed) return;
        Save(); disposed = true; lifetime.Cancel();
        frames.Stop(); samples.Stop(); tray.Visible = false; tray.Dispose();
        if (powerRegistration != IntPtr.Zero) Native.UnregisterPowerSettingNotification(powerRegistration);
        windowSource?.RemoveHook(WindowMessage);
        SystemEvents.PowerModeChanged -= PowerChanged; SystemEvents.SessionSwitch -= SessionChanged;
        SystemEvents.DisplaySettingsChanged -= DisplayChanged;
    }
}
