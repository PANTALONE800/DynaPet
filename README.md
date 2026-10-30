# DynaPet

一个源码公开的跨平台桌宠引擎（自带演示角色）。macOS 使用 SwiftUI / AppKit，Windows 使用 C# / .NET 10 LTS + WPF。

> **使用与商业限制**
>
> DynaPet 引擎代码采用 PolyForm Noncommercial 1.0.0，属于非商用源码公开项目。未经权利人另行授权，不得将受本许可约束的代码及其修改版用于商业用途，包括改名、换皮、重新打包后出售。
>
> 非商业使用、修改和再分发须遵守 [LICENSE](LICENSE)，并保留规定的许可及版权通知。第三方组件和另有声明的素材按其各自许可处理。

## 下载与安装

请在本仓库的 **Releases** 页面下载对应平台的安装压缩包。GitHub 的 Code → Download ZIP 下载的是源码，运行应用请使用 Release 附件。

| 平台 | 下载文件 | 安装方式 |
| --- | --- | --- |
| Windows x64 | `DynaPet-Windows-x64-v3.4.0-public-demo.zip` | 解压完整文件夹，运行 `DynaPet.exe`；自带 .NET 运行时。 |
| macOS Apple Silicon | `DynaPet-macOS-AppleSilicon-v3.4.0-public-demo.zip` | 需要 macOS 14+，解压后将 `DynaPet.app` 拖入“应用程序”，先退出旧版再打开。 |

应用通过右键菜单和菜单栏／系统托盘操作及退出。macOS 不显示 Dock 图标。当前为测试版：macOS 尚未经过 Apple 公证，Windows 尚未完成原生 GUI 全面实机验证。验证范围与安全说明见 [SECURITY.md](SECURITY.md)。

Release 提供 `SHA256SUMS.txt`，可使用 macOS 的 `shasum -a 256 文件名.zip` 或 Windows PowerShell 的 `Get-FileHash 文件名.zip -Algorithm SHA256` 核对。

## DynaPet 与动态主题

工程与应用已改名为 DynaPet，默认演示素材独立于引擎。macOS（Swift/ImageIO）与 Windows（C#/WPF/GDI+）现提供同格式动态 GIF 主题加载、完整帧时序和循环播放；原有 11 组动作与状态机继续保留。Windows 原生 GUI 与解码实测需在 Windows 完成。

右键桌宠或打开状态栏／托盘菜单，选择“导入主题包…”，选取解压后含 `theme.json` 的目录。试用 [MinimalGif 测试主题](TestThemes/MinimalGif) 或 [ZIP](TestThemes/MinimalGif.zip)。主题格式、限制、状态映射及两端验证命令见 [共享规范](IPCDemo/SharedSpec/ThemePackageSpec.md)。

- `DynaPet/`：完整 macOS 应用。
- `DynaPetNative/`：Swift 规则兼容入口与原生窗口包装。
- `IPCDemo/WindowsPlatform/`：Windows WPF 工程，入口 `App/DynaPet.Windows.csproj`。
- `DemoTheme/`：默认演示主题，包含原创几何角色的 11 组横向三帧动作及 `manifest.json`；代码按主题数据读取，不依赖角色名称。
- `Branding/`：独立的 DynaPet 引擎图标。

默认 macOS Bundle ID 为 `io.github.pantalone800.dynapet`；Windows 程序名、程序集、命名空间、设置目录与登录项使用 DynaPet。

## 首次启动

直接读取默认 `DemoTheme`，显示演示角色，播放欢迎动作后进入环境感知状态。右键菜单与菜单栏／托盘使用 DynaPet 名称；状态面板默认收起，可从菜单展开。

首次启动不自动开启消息感知、OCR 或登录启动，不弹首次启动向导。macOS 为 accessory GUI，无 Dock 图标；Windows 为无控制台 GUI，托盘提供操作与退出入口。原有功能与基础换图入口保留，导入静态图片不会自动生成动作；动态主题播放用户提供的 GIF 动画。

更名使用独立的设置和登录项标识，不自动修改旧版本的偏好或登录项；此前启用的旧版登录启动需在旧版中关闭。

## macOS 构建

需要 macOS 14+、Xcode Command Line Tools 和 Python 3。在项目根目录执行：

```sh
make package
```

也可执行 `make -C IPCDemo package`。当前 Apple Silicon 输出：

```text
IPCDemo/dist/arm64/DynaPet.app
  Contents/MacOS/DynaPet
  Contents/Frameworks/libpetbridge.dylib
  Contents/Resources/DemoTheme/
```

构建只生成应用并检查签名，不自动启动桌宠或申请隐私权限。

## Windows 构建

需要 .NET SDK 10.0.403 或兼容补丁。推荐在仍受支持的 Windows 11 x64 上运行。

```powershell
dotnet build IPCDemo/WindowsPlatform/App/DynaPet.Windows.csproj -c Release -r win-x64 --self-contained true
```

程序集和应用入口均使用 DynaPet；默认 DemoTheme 作为只读资源嵌入。Windows 不包含消息监听、消息提醒或聊天软件状态。

## 许可与素材

引擎代码采用 [PolyForm Noncommercial 1.0.0](LICENSE) 非商用许可，范围见 [LICENSE_SCOPE.md](LICENSE_SCOPE.md)。这是非商用源码公开，不属于 OSI 定义的开源许可。

本公开快照的默认演示素材为原创几何圆点，采用 CC0-1.0；不含历史角色图片。用户导入主题的图片权利仍由其权利人保留。

第三方组件声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，隐私说明见 [PRIVACY.md](PRIVACY.md)。
