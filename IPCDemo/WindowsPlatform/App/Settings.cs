using System;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using Microsoft.Win32;

namespace DynaPet.Windows;

internal sealed class Settings
{
    internal static string DirectoryPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DynaPet");
    private static string FilePath => Path.Combine(DirectoryPath, "settings.json");
    public double Scale { get; set; } = 1;
    public double? Left { get; set; }
    public double? Top { get; set; }
    public bool Details { get; set; } = false;
    public bool Animate { get; set; } = true;
    public string? Theme { get; set; }
    internal static Settings Load()
    {
        try
        {
            var value = JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath)) ?? new();
            if (value.Scale is not (.75 or 1 or 1.25)) value.Scale = 1;
            if (value.Left is { } x && !double.IsFinite(x)) value.Left = null;
            if (value.Top is { } y && !double.IsFinite(y)) value.Top = null;
            return value;
        }
        catch { return new(); }
    }
    internal void Save()
    {
        Directory.CreateDirectory(DirectoryPath);
        var tmp = FilePath + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(tmp, FilePath, true);
    }
    private const string RunPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    internal static bool StartupEnabled
    {
        get { using var key = Registry.CurrentUser.OpenSubKey(RunPath); return key?.GetValue("DynaPet") is string; }
    }
    internal static void Startup(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunPath);
        if (enabled) key.SetValue("DynaPet", "\"" + Environment.ProcessPath + "\"");
        else key.DeleteValue("DynaPet", false);
    }
    internal static void Open(string target) => Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
}
