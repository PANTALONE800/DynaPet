# libpetbridge 最小验证

已完成纯 Mac 动态库的编译、动态链接和 Swift 调用。这里只验证创建窗口、置顶和销毁，不接入业务或替换现有 AppKit 适配器。

## 构建产物

当前机器为 Apple Silicon arm64。默认使用 uname -m 选择架构；Intel Mac 可使用 ARCH=x86_64。动态库与 Swift 程序使用同一个 ARCH 和 macOS 14.0 最低目标。

```sh
make -C IPCDemo/MacPlatform/Bridge/PetBridge all verify print-config
make -C IPCDemo/MacPlatform/Bridge/PetBridge smoke
make -C IPCDemo/MacPlatform/Bridge/PetBridge leaks
```

本机实际产物：

- `<repository>/IPCDemo/.build/petbridge/arm64/Frameworks/libpetbridge.dylib`
- `<repository>/IPCDemo/.build/petbridge/arm64/bin/petbridge-smoke`

`lipo -info` 对两者均返回 arm64；`nm -gU` 确认三个公共操作函数已经导出。

## 实际链接方式

本次使用 Make＋clang＋swiftc，不是 Xcode 工程或 Swift Package Manager 构建。Swift 通过 include/module.modulemap 导入纯 C 头文件；以下是实际通过验证的配置，不把未运行过的 SPM 配置当成成功证据。

| 项目 | 实际值 |
|---|---|
| C 编译架构 | `-arch arm64` |
| Swift 编译目标 | `-target arm64-apple-macos14.0` |
| 头文件／模块查找 | `-I <PetBridge>/include` |
| Library Search Path | `-L <build>/Frameworks` |
| 链接库 | `-lpetbridge` |
| 动态库 install name | `@rpath/libpetbridge.dylib` |
| Runpath Search Path | `@executable_path/../Frameworks` |
| swiftc 对应参数 | `-Xlinker -rpath -Xlinker @executable_path/../Frameworks` |

`otool -L` 显示测试程序真正依赖 @rpath/libpetbridge.dylib，`otool -l` 显示 LC_RPATH；不是静态链接，也不需要设置 DYLD_LIBRARY_PATH。

本机 Swift 工具链历史上存在重复模块声明，因此 Makefile 在构建目录生成局部 VFS overlay；不修改系统模块文件。

## API 与所有权

公开头文件是纯 C ABI；内部 src/pet_bridge.m 使用 Objective-C＋ARC 调用 AppKit。没有 Win32／Linux 条件实现。

- `bridge_create_test_window()` 返回不透明 C 句柄。
- `bridge_set_topmost(handle, 1)` 在主线程设置 NSFloatingWindowLevel，返回 0 表示成功。
- `bridge_destroy_window(handle)` 关闭窗口并释放句柄；NULL 是无操作。
- C 只 free 自己 calloc 的句柄；原生窗口的 __bridge_retained 与 __bridge_transfer 一一配对，再由 ARC 释放。
- Swift 只持有不透明指针，在 defer 中调用 destroy；不得 free、deallocate 或解引用。UI 调用必须在主线程。

## 实测结果

最小调用完成后：live_handles=0，live_native_windows=0；窗口 level=3（floating）。独立 leaks --atExit 检查退出码 0，报告：

```text
0 leaks for 0 total leaked bytes.
```

最初 leaks 提示测试程序不可调试；随后只给独立 smoke 程序签入 get-task-allow，复检无该限制提示。此签名只用于测试，不用于发布，不改变系统安全设置或桌宠签名。

完整日志：项目 verification/petbridge-link.log、verification/petbridge-leaks.log。以上结果仅证明本次最小调用没有检测到泄漏，不声称覆盖尚未编写的桥接功能。
