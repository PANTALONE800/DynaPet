using System;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using DynaPet.Core;

namespace DynaPet.Windows;

internal static class OcrHost
{
    internal static int RunWorker(IntPtr window, string pipe, int parentPid, bool transportCheck = false)
    {
        // WinExe can have no standard handles; communication must not use Console APIs.
        if (!pipe.StartsWith("dynapet-ocr-", StringComparison.Ordinal)) return 2;
        _ = Task.Run(async () =>
        {
            try { using var parent = Process.GetProcessById(parentPid); await parent.WaitForExitAsync(); }
            catch { }
            Environment.Exit(0);
        });
        var exit = 0;
        var thread = new Thread(() =>
        {
            OcrResult result;
            try
            {
                var text = transportCheck ? "DynaPet OCR channel 中文" : WindowOcr.Read(window).GetAwaiter().GetResult();
                result = text.Length > 0 ? new(true, text, "") : new(false, "", "识别已完成，但没有检测到文字。请确认窗口中有清晰的文字。");
            }
            catch (OcrUnavailableException error) { result = new(false, "", error.Message); }
            catch (Exception error) { result = new(false, "", $"识别引擎异常（{error.GetType().Name}，0x{error.HResult:X8}），请检查系统 OCR 组件。"); }
            try
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                OcrChannel.Send(pipe, result, timeout.Token).GetAwaiter().GetResult();
            }
            catch { exit = 3; }
        });
        thread.SetApartmentState(ApartmentState.MTA); thread.Start(); thread.Join();
        return exit;
    }
    internal static Task<OcrResult> Read(IntPtr handle, CancellationToken token) => ReadCore(handle, token, false);
    internal static Task<OcrResult> Check(CancellationToken token) => ReadCore(IntPtr.Zero, token, true);
    private static async Task<OcrResult> ReadCore(IntPtr handle, CancellationToken token, bool check)
    {
        var pipe = OcrChannel.NewName();
        using var server = OcrChannel.Create(pipe);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        using var process = new Process { StartInfo = new ProcessStartInfo(Environment.ProcessPath!)
        { UseShellExecute = false, CreateNoWindow = true } };
        process.StartInfo.ArgumentList.Add(check ? "--ocr-channel-check" : "--ocr-window");
        if (!check) process.StartInfo.ArgumentList.Add(handle.ToInt64().ToString());
        process.StartInfo.ArgumentList.Add(pipe); process.StartInfo.ArgumentList.Add(Environment.ProcessId.ToString());
        try
        {
            process.Start();
            return await OcrChannel.Receive(server, timeout.Token);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { return new(false, "", "识别已取消"); }
        catch (OperationCanceledException)
        {
            var detail = process.HasExited ? $"辅助进程已退出，代码 {process.ExitCode}" : "窗口捕获或识别超过 20 秒";
            return new(false, "", $"识别未完成：{detail}；桌宠可继续使用。");
        }
        catch (Exception error) { return new(false, "", $"识别通道失败（{error.GetType().Name}，0x{error.HResult:X8}）。"); }
        finally { try { if (!process.HasExited) process.Kill(true); } catch { } }
    }
}
