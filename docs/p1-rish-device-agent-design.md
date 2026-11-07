# P1 · Rish 设备控制接入决策

## 平台与交付范围

| 路径 | 首个验收目标 | 分发边界 |
| --- | --- | --- |
| Android 普通包 | 系统连接器、明确的应用打开或分享入口，原生业务回执 | Google Play 对 Accessibility API 的自主发起、规划和执行有明确限制。普通包的 Agent 不注册通用 UI 自主执行工具。[Google Play 政策](https://support.google.com/googleplay/android-developer/answer/18265346?hl=en#accessibility_api) |
| Android 单独实验 | 用户在系统设置主动授权，前台测试 App 完成观察、一次非破坏性点击和结果核对。截图、节点树、手势分别测试和声明 | 先验证非 Root、无 ADB 的应用路径。逐项核对 API 版本、权限撤销、受保护窗口和 OEM 差异，分发前再按渠道复核。[AccessibilityService](https://developer.android.com/reference/android/accessibilityservice/AccessibilityService) |
| iOS 普通包 | 自有 App Intents、用户显式选择的系统交互与有明确权限的系统连接器。启动或交接结果与业务执行结果分别报告 | App Intents 暴露应用自有动作。通用跨 App 节点观察、截图和点击在普通包能力表标为 `unsupported`。发布包以公开 API 和各自适用的审核条款为边界。[App Intents](https://developer.apple.com/documentation/appintents) · [App Review 2.5](https://developer.apple.com/app-store/review/guidelines/#software-requirements) |
| iPhone 桌面实验 | 对已授权的测试设备，单独验证开发服务或 WDA 路径。先完成只读观察，再发送一次有后置条件的动作 | 主机、配对、设备解锁、测试服务与系统版本属于显式前提。Simulator 与物理 iPhone 的结果分别记录。[XCUIAutomation](https://developer.apple.com/documentation/xcuiautomation) · [Poki 调研](p1-poki-source-review.md) |

## 共享 Rust 契约草案

- `device.capabilities` 按工具返回 `supported`、`permission_required`、`temporarily_unavailable` 或 `unsupported`。适配器类型、权限版本与窗口状态来自平台；Rust 按构建渠道、任务权限及运行时状态生成工具投影。首版以新工具集版本或实验 profile 接入，保留现有持久化工具摘要的兼容性。[现有工具注册](../modules/rish/core/crates/rish-agent-core/src/tool_registry.rs)
- `device.observe` 产生有界的节点树和短期 `observation_id`。观察记录绑定设备、会话、前台应用、窗口、显示区域、方向、屏幕世代和失效时刻。截图单独声明并按需取用，任务日志保存状态与摘要。节点引用只在该快照内有效。
- `device.act` 接受快照引用、动作类型、参数和调用 ID。先核对同一设备的独占租约、动作权限、审批和预算；原生端在调用系统 API 前复核当前前台、窗口、屏幕世代和目标。权限变化、用户接管或窗口切换会失效旧观察。平台可返回 `stale_observation` 要求重新观察，不自动重用坐标。
- 回执区分派发状态 `not_sent`、`sent`、`unknown` 与验证状态 `confirmed`、`unconfirmed`、`not_applicable`。验证使用动作专属的后置条件。超时或取消保留已知派发事实，未知结果进入只读核对，不自动重放。任务复用 Rust 的审批、ledger 和 round journal。[执行协议](../modules/rish/core/crates/rish-agent-core/src/tool_execution.rs) · [轮次日志](../modules/rish/core/crates/rish-agent-core/src/round_journal.rs)
- 同一设备的写租约绑定任务和会话。停止时先停止受理并取消队列，等待在途操作明确收尾或标记未知，再交接租约。Android 和 iOS 桥只持有必要的原生能力和生命周期状态；设备写入与 [业务连接器](p1-connector-boundaries.md) 各自形成回执。

## 实现与验收顺序

1. 先在共享 Rust 注册实验工具集与假桥，覆盖两任务争租约、旧观察、前台切换、撤销授权、取消晚到与未知结果不重放。使用现有工具调用入口记录审批与回执。
2. Android 独立实验覆盖两个厂商的真机和 API 边界。首条闭环为测试 App 从“待处理”到“完成”，手动切换前台、撤销权限和锁屏都必须使动作失败或明确转人工。增加中文输入、旋转和多窗口后再扩大范围。
3. iOS 普通包先验证用户授权的日历只读和自有 App Intent，在 iPhone 与 iPad 核对权限撤销。桌面桥另开实验，记录读、触控、文本和启动各自的设备前提与真实回执。

本轮交付平台决策和契约草案。平台适配器、连接器实现和真机验收列入 P2。
