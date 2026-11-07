# P1 · 连接器与任务入口

| 能力 | Mika | Poki | Rish 决策 |
| --- | --- | --- | --- |
| 原生业务接口 | `CalendarBulkWriter` 在 App 进程调用 `CalendarContract`，选择可见、可写的日历。清单声明读写授权。[日历源码][mika-calendar] | `list_apps`、`launch_app`、粘贴板等由设备桥执行。源码和工具目录将它们建模为设备操作。[工具目录][poki-tools] | 先交付日历只读垂直切片，后续创建日程单独授权并核对事件 ID。打开日历界面只能返回设备回执。 |
| 扩展工具 | 核心有 HTTP、旧版 SSE、stdio MCP 客户端与 OAuth 实现，手机还能通过令牌保护的 USB 转发或受信网络向桌面提供任务入口。[MCP 客户端][mika-mcp] · [电脑接入][mika-computer] | stdio 代理连本机 MCP daemon，daemon 校验令牌并按会话处理调用和取消。设备工具有只读标记与单独审批路径。[stdio][poki-stdio] · [daemon][poki-daemon] | 连接器提供独立工具清单、账户及范围。远程 MCP 候选先做显式 HTTPS 地址和只读工具白名单。stdio、外部工具写入与桌面代理分别验收。 |
| 技能与消息渠道 | 个人技能导入、工作区脚本同步，桌面 CLI、Skill、MCP 可提交或观察同一任务。[技能][mika-skill] · [电脑接入][mika-computer] | 桌面 Agent 用 pi 接终端，iMessage 依赖 BlueBubbles、Messages 会话和用户授权，Telegram 工作者有发送者白名单。仓库分别记录模拟渠道与真实投递的边界。[Agent][poki-agent] · [iMessage 网关][poki-message] | Bot 渠道复用任务 ID、取消和权限边界。渠道身份、业务连接器凭据、模型凭据分别管理。渠道能收发消息不能赋予设备控制权。 |

首批可实施的连接器记录包含 `connector_id`、`schema_version`、平台、账号引用、工具 schema、读写范围及状态。凭据由原生安全存储持有，任务只拿账号引用和被授予的动作范围。账户过期和撤销立即影响后续工具投影。写入绑定任务、账号、参数摘要和幂等键，结果不明时先查询账本或目标资源。模型与用户回执分别展示已确认的事实和待核对状态。

Mika 和 Poki 的源代码、许可及原生依赖各自列在 [Mika 调研](p1-mika-source-review.md) 和 [Poki 调研](p1-poki-source-review.md)。本轮采用任务与工具边界设计，原生业务连接器和远程 MCP 客户端由 Rish 实现。

[mika-calendar]: https://github.com/wangzan101/mika/blob/f3bbbdf92caeb4259d55922e12f61f6da11469fd/app/src/main/java/com/wangzan101/mika/cap/phone/a11y/CalendarBulkWriter.kt
[mika-mcp]: https://github.com/wangzan101/mika/tree/f3bbbdf92caeb4259d55922e12f61f6da11469fd/core/src/main/kotlin/com/wangzan101/mika/core/cap/mcp
[mika-computer]: https://github.com/wangzan101/mika/blob/f3bbbdf92caeb4259d55922e12f61f6da11469fd/docs/computer.en.md
[mika-skill]: https://github.com/wangzan101/mika/blob/f3bbbdf92caeb4259d55922e12f61f6da11469fd/core/src/main/kotlin/com/wangzan101/mika/core/skills/SkillImport.kt
[poki-tools]: https://github.com/JosssphZhou/poki/blob/d2837bf08357c82a6e3be415b83697601336f583/docs/tools.md
[poki-stdio]: https://github.com/JosssphZhou/poki/blob/d2837bf08357c82a6e3be415b83697601336f583/src/stdio.mjs
[poki-daemon]: https://github.com/JosssphZhou/poki/blob/d2837bf08357c82a6e3be415b83697601336f583/src/daemon.mjs
[poki-agent]: https://github.com/JosssphZhou/poki/blob/d2837bf08357c82a6e3be415b83697601336f583/agent/README.md
[poki-message]: https://github.com/JosssphZhou/poki/blob/d2837bf08357c82a6e3be415b83697601336f583/docs/imessage-gateway.md
