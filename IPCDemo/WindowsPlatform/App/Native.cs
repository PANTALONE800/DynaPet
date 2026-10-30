using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using DynaPet.Core;

namespace DynaPet.Windows;

internal static class Native
{
    internal delegate bool EnumCallback(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] internal static extern bool EnumWindows(EnumCallback callback, IntPtr data);
    [DllImport("user32.dll")] internal static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] internal static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] internal static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, StringBuilder text, int count);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder text, int count);
    [DllImport("user32.dll")] internal static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] internal static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
    [DllImport("user32.dll")] private static extern bool GetLastInputInfo(ref LastInput input);
    [DllImport("kernel32.dll")] private static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
    [DllImport("kernel32.dll")] private static extern bool GetSystemPowerStatus(out PowerStatus status);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("powrprof.dll")] private static extern uint PowerGetActiveScheme(IntPtr root, out IntPtr scheme);
    [DllImport("powrprof.dll")] private static extern uint PowerReadACValueIndex(IntPtr root, ref Guid scheme, ref Guid subgroup, ref Guid setting, out uint value);
    [DllImport("powrprof.dll")] private static extern uint PowerReadDCValueIndex(IntPtr root, ref Guid scheme, ref Guid subgroup, ref Guid setting, out uint value);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
    [DllImport("user32.dll")] internal static extern IntPtr RegisterPowerSettingNotification(IntPtr recipient, ref Guid setting, uint flags);
    [DllImport("user32.dll")] internal static extern bool UnregisterPowerSettingNotification(IntPtr registration);
    [DllImport("user32.dll")] internal static extern IntPtr GetWindowLongPtrW(IntPtr window, int index);
    [DllImport("user32.dll")] internal static extern IntPtr SetWindowLongPtrW(IntPtr window, int index, IntPtr value);
    [StructLayout(LayoutKind.Sequential)] internal struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct LastInput { public uint Size, Tick; }
    [StructLayout(LayoutKind.Sequential)] private struct PowerStatus { public byte AC, Flag, Percent, Reserved; public uint Life, FullLife; }
    [StructLayout(LayoutKind.Sequential)] private struct MonitorInfo { public uint Size; public Rect Monitor, Work; public uint Flags; }
    internal static string Title(IntPtr window) { var b = new StringBuilder(2048); GetWindowText(window, b, b.Capacity); return b.ToString(); }
    internal static string ClassName(IntPtr window) { var b = new StringBuilder(256); GetClassName(window, b, b.Capacity); return b.ToString(); }
    internal static string ProcessName(uint pid) { try { using var p = Process.GetProcessById((int)pid); return p.ProcessName; } catch { return ""; } }
    internal static List<IntPtr> Windows()
    {
        var result = new List<IntPtr>();
        EnumWindows((w, _) => { if (IsWindowVisible(w)) result.Add(w); return true; }, IntPtr.Zero);
        return result;
    }
    internal static uint Owner(IntPtr w) { GetWindowThreadProcessId(w, out var pid); return pid; }
    internal static (double Width, double Height) WorkArea(IntPtr handle)
    {
        var info = new MonitorInfo { Size = (uint)Marshal.SizeOf<MonitorInfo>() };
        if (handle == IntPtr.Zero || !GetMonitorInfo(MonitorFromWindow(handle, 2), ref info)) return (1280, 720);
        var scale = Math.Max(96, GetDpiForWindow(handle)) / 96.0;
        return ((info.Work.Right - info.Work.Left) / scale, (info.Work.Bottom - info.Work.Top) / scale);
    }
    internal static void Place(IntPtr handle, bool reset)
    {
        var monitor = MonitorFromWindow(handle, reset ? 1u : 2u); // primary on reset; nearest otherwise
        var info = new MonitorInfo { Size = (uint)Marshal.SizeOf<MonitorInfo>() };
        if (!GetMonitorInfo(monitor, ref info) || !GetWindowRect(handle, out var rect)) return;
        var width = rect.Right - rect.Left; var height = rect.Bottom - rect.Top;
        var gap = (int)(40 * GetDpiForWindow(handle) / 96.0);
        var x = reset ? info.Work.Left + (info.Work.Right - info.Work.Left - width) / 2 : rect.Left;
        var y = reset ? info.Work.Bottom - height - gap : rect.Top;
        x = Math.Clamp(x, info.Work.Left, Math.Max(info.Work.Left, info.Work.Right - width));
        y = Math.Clamp(y, info.Work.Top, Math.Max(info.Work.Top, info.Work.Bottom - height));
        SetWindowPos(handle, IntPtr.Zero, x, y, 0, 0, 0x0015); // no size, no Z order, no activation
    }
    internal static double ScreenTimeout(bool ac)
    {
        if (PowerGetActiveScheme(IntPtr.Zero, out var pointer) != 0) return 0;
        try
        {
            var scheme = Marshal.PtrToStructure<Guid>(pointer);
            var subgroup = new Guid("7516b95f-f776-4464-8c53-06167f40cc99");
            var setting = new Guid("3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e");
            uint value;
            var error = ac ? PowerReadACValueIndex(IntPtr.Zero, ref scheme, ref subgroup, ref setting, out value)
                : PowerReadDCValueIndex(IntPtr.Zero, ref scheme, ref subgroup, ref setting, out value);
            return error == 0 ? value : 0;
        }
        finally { LocalFree(pointer); }
    }
    internal sealed class Sensors
    {
        private long priorIdle, priorTotal;
        private double cpu;
        private long wake = Environment.TickCount64;
        private volatile bool resetWake;
        internal void Wake() { resetWake = true; }
        internal Snapshot Sample()
        {
            if (resetWake) { resetWake = false; wake = Environment.TickCount64; priorTotal = 0; }
            if (GetSystemTimes(out var idle, out var kernel, out var user))
            {
                var total = kernel + user;
                if (priorTotal > 0 && total > priorTotal)
                    cpu = cpu * .55 + Math.Clamp(100 * (1 - (double)(idle - priorIdle) / (total - priorTotal)), 0, 100) * .45;
                priorIdle = idle; priorTotal = total;
            }
            var powerOk = GetSystemPowerStatus(out var power);
            int? battery = powerOk && power.Percent <= 100 && (power.Flag & 128) == 0 ? power.Percent : null;
            var ac = powerOk && power.AC == 1;
            var last = new LastInput { Size = (uint)Marshal.SizeOf<LastInput>() };
            var idleSeconds = GetLastInputInfo(ref last) ? unchecked((uint)Environment.TickCount - last.Tick) / 1000.0 : 0;
            var handles = Windows().Where(w => Title(w).Length > 0 && Owner(w) != Environment.ProcessId &&
                (GetWindowLongPtrW(w, -20).ToInt64() & 0x80) == 0 && ClassName(w) is not ("Progman" or "WorkerW" or "Shell_TrayWnd")).ToArray();
            var apps = handles.Select(Owner).Distinct().Count();
            var folders = handles.Count(w => ClassName(w) == "CabinetWClass");
            var documents = handles.Count(w => Regex.IsMatch(Title(w), @"\.(docx?|xlsx?|pptx?|pdf|txt|md|rtf|odt|ods|odp)(\b|$)", RegexOptions.IgnoreCase));
            var front = ProcessName(Owner(GetForegroundWindow()));
            if (front == "explorer" && ClassName(GetForegroundWindow()) != "CabinetWClass") front = "桌面";
            return new(cpu, battery, ac, apps, handles.Length, folders, documents, front,
                idleSeconds, (Environment.TickCount64 - wake) / 1000.0, ScreenTimeout(ac));
        }
    }
}
