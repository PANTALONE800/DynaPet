# DynaPet Windows

C# / .NET 10 LTS + WPF。应用程序集 DynaPet，代码命名空间 DynaPet.Windows 与 DynaPet.Core。入口 App/DynaPet.Windows.csproj。

默认 DemoTheme 以 DynaPet.DemoTheme.* 资源名嵌入，自有状态规则与角色名称分离。首次启动显示演示角色，状态面板收起；托盘和右键菜单提供控制，不自动启用 OCR 或登录启动。Windows 不包含消息监听。

```powershell
dotnet build IPCDemo/WindowsPlatform/App/DynaPet.Windows.csproj -c Release -r win-x64 --self-contained true
```

动态 GIF 主题引擎与完整时间轴已接入，主题格式见 SharedSpec/ThemePackageSpec.md。现有业务功能保留，Windows 实际 GUI 仍需在目标电脑验证。
