# Android P0 模型发现与 Codex 单轮加固 · 2026-11-07

| 轮次 | 结果 |
| --- | --- |
| 1 | 内置服务商拉取取消使用控制队列，避免等待繁忙的 I/O worker。 |
| 2 | 内置与自定义拉取在排队前登记操作，排队时即可按操作 ID 取消。 |
| 3 | HTTP 或解析拒绝回传前重新核对配置和凭据，旧账号的拒绝不会覆盖新账号状态。 |
| 4 | 预览订阅异常只关闭预览，已收到的有效回答可正常写入原生日志。 |
| 5 | Codex 派发前取消保留未发送的证明，写入 `cancelled` 并释放执行槽。 |
| 6 | 带有错误字段的终止帧无法提交回答。 |
| 7 | 同一 Codex 流式事件 ID 必须保持类型一致，推理事件无法转成文本结果。 |
| 8 | 发出用户提示前核对线程回报的只读策略、网络限制和审批设置。 |
| 9 | 在应用 UID 下运行固定版本的沙箱写入对照，记录实际启动结果。 |
| 10 | 模型拉取结果与取消通过同一个保留记录仲裁，终止后释放记录。 |

第 8 轮对照了 [Codex 0.153.4 的线程响应 schema](https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/app-server-protocol/schema/json/v2/ThreadStartResponse.json)。
第 9 轮使用该版本的 [Linux 调试沙箱入口](https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/cli/src/debug_sandbox.rs)。
普通命令读取并写入了临时测试文件。沙箱路径返回 `bubblewrap_unavailable` 和退出码
`101`，未进入测试命令，也未写入文件。这定位了当前 Android 包的启动阻塞。文件隔离、
真实账号及模型、工具工作负载和进程树清理仍待验证，应用目录继续显示 Codex 执行不可用。

## 验收

- Android JVM **156 项通过**。源码预检 **25 项通过**，离线 checkout 检查通过。
- 断网 Pixel XL API 33 arm64 模拟器上，开发包 **43 项通过**，普通包 **31 项通过**。
  开发包用固定版本的 Codex 通过无凭据的回环 SSE 夹具完成单轮，并写入原生日志。
  设备进程检查确认测试后没有残留 Codex 进程。
- Android 源码与测试 APK 均重新构建。共享 Rust 源码沿用 `1b047e23`，复用本地已有
  JNI 库。本轮验证限于 Android 模拟器，iOS 与真机仍待验。
- 重用现有 Gradle 输出路径和 Codex 输入。普通 APK 恢复至 **31.2 MiB**，
  与测试 APK 一并保留。普通 APK 内无 Codex 二进制和探测清单，两个 CLI 开关均为
  `false`。Gradle app 构建目录为 **579 MiB**，较本轮开始时的 **576 MiB** 增加约 **3 MiB**。

| Android 产物 | SHA-256 |
| --- | --- |
| `app-debug.apk` | `5589e21485ae9add93aa1ed04b0f4caf033ad38986ffc88a09b4476693cf7aaf` |
| `app-debug-androidTest.apk` | `d07b23a118501cdbfeff18b7299eba2db27088112cb80378847c26aa3fdf12ec` |
