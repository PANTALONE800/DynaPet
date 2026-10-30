# 桌宠核心规格草稿 v0.1

> Windows 产品范围更新（2026-10-29）：已选 C# / .NET 8 + WPF，完整保留非消息桌宠业务；明确移除消息监听、消息提醒与聊天软件状态。以下仍描述分层 Swift 参考入口，其 pet.touch=happy 不覆盖原版完整桌宠 touch=shy 的行为。Windows 以原版 7 秒摸摸保持／严格大于 9 秒切换迟滞／14 秒欢迎和全部 11 组动作实现；message 素材仅为“惊喜”手动预览。窗口 OCR 保留为主动确认后的单次工具。当前产品功能对照与验证范围以 WindowsPlatform/README.md 为准。

用途：供 Windows C#／.NET 8 实现对照，复现现有状态、动作与数据合同。Mac 使用 Swift＋AppKit，必要系统功能由纯 Mac C 桥接提供；Windows 自行使用 C#＋WPF 或 WinUI 3，实现相同行为，无需 Swift、Electron 或 C 桥接。UI 框架选型不改变以下规则。

这是当前已实现行为的规格，不代表消息监听、OCR、登录启动等功能已经迁移完毕。Swift 参考实现位于 `Swift/`，不是 Windows 的运行依赖。

## 1 输入与状态

| 数据 | 类型／单位 | 语义 |
|---|---|---|
| cpu | 有限数，0～100 | 已平滑的 CPU 百分比；Mac 参考：旧值×0.55＋本次值×0.45 |
| battery | 可空整数，0～100 | 未提供为 null，不得当作 0 |
| charging | 布尔 | 兼容字段名；当前实际表示接通外接电源，不仅是“正在充电” |
| apps | 非负整数 | 普通用户应用数量，不是所有后台进程数 |
| windows／folders／documents | 可空非负整数 | 平台公开的窗口／文件夹／文档计数；未提供为 null |
| front | 字符串 | 当前前台应用；匹配前转小写。Windows 适配层需补充应用名归一化 |
| idle／awake／screenTimeout | 秒 | 用户闲置时长／本次唤醒或会话时长／屏幕睡眠阈值；阈值≤0 表示禁用该项预测 |
| mood／text／scale／revision | 字符串／字符串／数值／整数 | 当前状态、文案、缩放、业务修订号；初始 scale=1、revision=0 |

通常每 3 秒采样；较重的窗口统计约每 12 秒采样。系统 API、权限和未知值判定归平台层。业务输入必须可注入，便于用同一组样例测试 C# 实现。

## 2 状态判定与覆盖顺序

自动判定严格从上到下，首项命中即返回；不要把条件改成并行竞争。

| 优先级 | 条件 | 结果 |
|---:|---|---|
| 1 | 业务初始化／唤醒后的 14 秒欢迎期内 | welcome |
| 2 | battery 已知且≤15，且 charging=false | low |
| 3 | idle>60，screenTimeout>0，且 idle≥max(60, screenTimeout−35) | sleepy |
| 4 | cpu>83 | dizzy |
| 5 | cpu>55，或 windows>24，或 apps>22 | hot |
| 6 | awake>3000，且 idle<60 | sleepy |
| 7 | idle>180 | sleepy |
| 8 | front 包含 code／xcode／terminal／终端 | focus |
| 9 | front 包含 wps／word／pages／excel／powerpoint | focus |
| 10 | front 包含 finder／访达 | puzzled |
| 11 | charging=true | happy |
| 12 | 其余 | idle |

输入阈值中的 `>` 与 `≥` 必须按表保留。未知窗口数在阈值比较时不命中，不表示界面应显示 0。Windows 文件管理器、终端和办公软件的识别映射由其平台适配层实现，不把 Mac API 搬入业务层。

控制规则：

- `start` 主动进入 welcome；系统睡眠进入 sleepy 并暂停环境更新，唤醒清除摸摸保持、重开 14 秒欢迎期。
- `pet.touch` 进入 happy，文案“嘿嘿，被你摸摸啦～”；UI 成功后保持约 7 秒，其间环境采样不覆盖该状态。重复摸摸重播动作并刷新保持时间。
- 保持期外，自动切换还需满足：目标 mood 与当前相同，或距最近 mood 改变严格超过 9 秒，或目标为 low／welcome。该规则仍可能延长摸摸后的实际保持时间。
- 只有 mood 改变才更新时间戳；同 mood 的文案更新、缩放不重置 9 秒计时。同 mood／同文案的重复采样不重播动画。
- 状态操作串行；窗口异步应用成功后才提交状态、增加 revision、推送事件和完成请求。失败不提交成功状态。停止后拒绝新操作并忽略迟到的环境更新。

## 3 十一组动作

资源为 `Assets/BustV3/<name>.png`，每张横向三格、透明背景。三帧共用裁剪区域与缩放，避免逐帧跳动。

| name | 触发条件 | 动作时长 D／周期 P（秒） |
|---|---|---:|
| welcome | 启动、唤醒、欢迎期 | 0.40／3.8 |
| idle | 自动规则兜底 | 0.30／4.6 |
| focus | 编程、终端、办公场景 | 1.15／3.4 |
| happy | pet.touch；或规则命中的外接电源状态 | 0.34／3.9 |
| hot | 中高 CPU、窗口或软件过多 | 1.20／2.7 |
| dizzy | cpu>83，且未被更高优先级覆盖 | 1.90／2.0 |
| puzzled | 文件管理场景 | 0.34／4.4 |
| sleepy | 系统睡眠、闲置或休息提醒 | 2.20／5.0 |
| low | 低电量且未接电源 | 1.15／3.1 |
| shy | 保留动作；旧原生版摸摸使用，新入口暂无触发路由 | 0.85／3.5 |
| message | 保留动作；旧原生版消息信号使用，新入口消息通道尚未迁入 | 0.32／4.0 |

动作序列为 `[0,1,2,2,1,0]`。首次播放立即从动作段开始：`phase=(P−D+elapsed)%P`；当 phase<P−D 时停在第 0 帧，否则 `i=clamp(floor((phase−P+D)/D×6),0,5)`，显示序列第 i 项。约 30 Hz 计时，帧索引变化时更新图像；动画不得阻塞业务队列或 UI 线程。

`shy`、`message` 的新触发合同必须另行确认，不能仅因素材存在就声称相关业务已完成。没有饥饿值、喂食或 AI 对话的既有规则。

## 4 JSON 数据合同 v1

这是可选诊断／进程间通信及跨语言验收合同。Windows 产品可用 C# 对象与事件在进程内实现，按需序列化；不要求启动 Electron 或子进程。

消息为 UTF-8 NDJSON，一行一条，以 LF 结束，接受 CRLF；JSON 本体≤65,536 字节。半行保留、多行分别解析；坏 JSON、坏结构、无效 UTF-8、超长行记录固定错误码后丢弃该行，继续收下一行。EOF 时丢弃不完整的尾行。协议走 stdout，诊断走 stderr，日志不回显坏消息正文。

公共字段固定为 `version`、`id`、`type`、`body`，拒绝多余字段。version 必须为数值 1；id 匹配 `[A-Za-z0-9_-]{1,64}`。method／事件名／错误码匹配 `[A-Za-z][A-Za-z0-9_.-]{0,63}`。

```json
{"version":1,"id":"r-1","type":"request","body":{"method":"pet.touch","params":{}}}
{"version":1,"id":"r-1","type":"response","body":{"ok":true,"result":{"accepted":true}}}
{"version":1,"id":"r-2","type":"response","body":{"ok":false,"error":{"code":"INVALID_PARAMS","message":"Unsupported scale"}}}
{"version":1,"id":"e-1","type":"event","body":{"name":"play_animation","seq":1,"data":{"name":"happy","reason":"touch","revision":2}}}
```

| type | body 精确字段 | 约束 |
|---|---|---|
| request | method、params | params 必须为对象；先白名单、再验证业务参数 |
| response 成功 | ok、result | ok 为 true；result 为对象；id 复用请求 id |
| response 失败 | ok、error | ok 为 false；error 精确含 code、message；message≤2048 UTF-8 字节 |
| event | name、seq、data | data 为对象；事件拥有独立唯一 id，不要求 request |

| method | params | 成功 result |
|---|---|---|
| pet.touch | `{}` | `{"accepted":true}` |
| pet.resize | 仅 `{"scale":0.75或1或1.25}` | 应用后的 scale；不接受布尔、字符串、额外字段 |
| ping | `{}` | `{"pong":true}` |
| echo | 任意合法 JSON 对象，仅测试用 | 原对象 |
| shutdown | `{}` | `{}`，随后清理并退出 |

线上的错误码包括 METHOD_NOT_FOUND、INVALID_PARAMS、OPERATION_FAILED、OPERATION_TIMEOUT。INVALID_REQUEST 是路由层防御错误；原始坏包或不可信 id 在解析层丢弃，不强行构造响应。

业务操作期限默认 3 秒；客户端请求默认也为 3 秒。超时终止等待，不等于取消已开始的 UI 动作；不自动重试。每个请求至多一个响应，迟到或重复完成不得产生第二个响应。参考实现最多 128 个在途请求，输出队列最多 512 KiB。

## 5 主动事件与界面边界

| 事件 | data |
|---|---|
| pet.state_changed | mood、text、scale、reason、revision |
| play_animation | name、reason、revision |
| pet.resized | scale、revision |
| core.ready | pid、nativeWindowVisible（Mac 验证入口字段） |
| core.stopping | reason |

reason 当前包括 startup、environment、touch、resize、sleep、wake。revision 初始为 0，每次成功提交加 1；同一次提交的事件共用 revision。seq 为进程会话内统一递增整数，范围 1～9007199254740991，生命周期与业务事件共用序列；重启后消费者重置序列基线。response 与 event 异步到达，不能假定先后顺序。启动 welcome 事件可以早于 core.ready。

窗口抽象覆盖显示、置顶、穿透、位置、缩放、动画、文案与关闭。坐标采用逻辑点／DIP、桌面左上为原点，y 向下；像素与系统坐标由平台适配层换算。当前参考基础尺寸 240×260，1.25 倍为 300×325。

UI 更新必须异步切到平台 UI 线程，成功回调表示已经应用；采样、阻塞 I/O 和业务状态队列不得占用 UI 主线程。Mac 保留 AppKit 实现；Windows 用其自己的 UI Dispatcher 和窗口实现。

## 6 C# 最小验收样例与未定范围

- 欢迎期内同时输入低电量：仍为 welcome；欢迎期结束、电量 15 且未接电：low；未知电量不触发 low。
- 排除高优先级后：cpu=83→hot，cpu>83→dizzy；cpu=55 且其他条件不命中→不因 CPU 进入 hot。
- pet.touch 后 7 秒内的高 CPU 采样不覆盖 happy；UI 失败不发成功状态事件。
- 连续相同采样不反复重启动画；三档缩放确实改变窗口；非法参数不触发窗口操作。
- 不发 request 也能收到 startup／environment 状态事件；事件 seq 单调递增、同一次提交 revision 相同。
- 半包、粘包、中文跨字节、坏行恢复、迟到完成、停止后更新，都有参考测试：`Tests/Swift/`。

待补充：消息信号／未读数／OCR、手动预览与暂停、登录启动、Windows 应用识别映射及系统权限规格。它们不属于当前新入口已完成的合同。WPF 与 WinUI 3 尚未选定；本规格不替选。
