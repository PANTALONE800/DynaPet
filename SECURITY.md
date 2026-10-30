# 安全与测试状态

本项目是尚未完成全平台实机验收的桌宠测试版本。源码审查、功能测试和签名／哈希校验不等于无漏洞证明、杀毒检测或安全认证。

- 不使用管理员权限运行；消息和 OCR 权限按需要授予，不需要时关闭。
- 不应为运行本应用关闭 Gatekeeper、SmartScreen、Defender、防火墙或系统安全服务。
- Mac 当前为 ad-hoc 签名，尚未 Developer ID 签名或 Apple 公证。Windows 当前未做 Authenticode 签名。
- Windows v3.3.0 已升级为 .NET 10.0.14 LTS，自带运行时，无需用户另装 .NET；本次核对的官方支持截止日为 2028-11-14。仍需随安全补丁重新打包，自带运行时不会跟随系统中其他 .NET 安装自动升级。
- 下载后可用同版本 `.sha256` 文件核对传输完整性。哈希一致只证明与所给文件一致，不证明文件没有恶意行为；应通过可信渠道确认发布者。
- Windows GUI、实际 OCR、多屏、睡眠与登录项仍需 Windows 实机回归。不要把 macOS 交叉编译或历史验证记录当作这些测试已通过。

目前尚未配置正式私密漏洞报告渠道。公开发布前应在 GitHub 启用 Private vulnerability reporting。不要在公开 Issue 上传密钥、聊天正文、私人截图、未经脱敏的 capabilities 或演示诊断。
