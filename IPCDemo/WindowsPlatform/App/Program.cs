using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows;
using System.Windows.Threading;

namespace DynaPet.Windows;

internal static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Length == 3 && args[0] == "--theme-check") return GifThemeChecks.Run(args[1], args[2]);
        if (args.Length == 4 && args[0] == "--ocr-window" && long.TryParse(args[1], out var window) && int.TryParse(args[3], out var parentPid))
        {
            return OcrHost.RunWorker(new IntPtr(window), args[2], parentPid);
        }
        if (args.Length == 3 && args[0] == "--ocr-channel-check" && int.TryParse(args[2], out var checkParent))
            return OcrHost.RunWorker(IntPtr.Zero, args[1], checkParent, true);
        if (args.Contains("--self-test"))
        {
            try
            {
                var sprites = new Sprites();
                if (sprites.Count != 11) return 1;
                var channel = OcrHost.Check(CancellationToken.None).GetAwaiter().GetResult();
                if (!channel.Ok || channel.Text != "DynaPet OCR channel 中文") return 2;
                var temporary = Directory.CreateTempSubdirectory("dynapet-theme-check-");
                try
                {
                    var image = Path.Combine(temporary.FullName, "角色图.png");
                    var png = new System.Windows.Media.Imaging.PngBitmapEncoder();
                    png.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(sprites.Frame(DynaPet.Core.Mood.Idle, 0)));
                    using (var output = File.Create(image)) png.Save(output);
                    var name = ThemeImporter.Import([image], temporary.FullName);
                    if (new Sprites(Path.Combine(temporary.FullName, name)).Count != 11) return 3;
                    var imported = ThemeImporter.Import([Path.Combine(temporary.FullName, name)], temporary.FullName);
                    if (new Sprites(Path.Combine(temporary.FullName, imported)).Count != 11) return 4;
                }
                finally { temporary.Delete(true); }
                var path = Path.Combine(AppContext.BaseDirectory, "self-test-result.txt");
                File.WriteAllText(path, "PASS: 11 embedded animations; single-image and folder import produce 11 loadable states; GUI child OCR pipe returns Chinese text; no pet window opened.\n");
                return 0;
            }
            catch { return 1; }
        }
        using var singleton = new Mutex(true, @"Local\DynaPet.Desktop.v3", out var first);
        using var show = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\DynaPet.Show.v3");
        if (!first) { show.Set(); return 0; }
        var app = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
        PetWindow? pet = null;
        var wait = ThreadPool.RegisterWaitForSingleObject(show, (_, _) => app.Dispatcher.InvokeAsync(() => pet?.ShowPet()), null, -1, false);
        try
        {
            pet = new PetWindow();
            app.MainWindow = pet;
            app.Run(pet);
            return 0;
        }
        catch
        {
            MessageBox.Show("DynaPet启动失败。请重新解压完整的 DynaPet.exe，并检查运行目录和临时目录是否可写。\n需要 Windows 10 2004 或更新版本。", "DynaPet", MessageBoxButton.OK, MessageBoxImage.Error);
            return 1;
        }
        finally { wait.Unregister(null); pet?.Dispose(); singleton.ReleaseMutex(); }
    }
}
