# P1 · Poki iPhone 源码调研

本轮固定提交 [d2837bf0](https://github.com/JosssphZhou/poki/tree/d2837bf08357c82a6e3be415b83697601336f583)。官方路径是 macOS 主机上的 Node MCP 服务与原生桥。物理设备、Simulator 和 WebDriverAgent 是分别有前提的路径。以下实机记录由上游提供，Rish 本轮只核对源码和记录。

| 路径 | 源码实现与运行前提 |
| --- | --- |
| 物理 iPhone | Rust 桥通过固定版本的 idevice 访问配对设备。AX 读取走远程无障碍服务，视频和输入走设备开发服务，应用枚举和启动走 CoreDevice AppService。需要先以 USB 信任主机，开启开发者模式与 UI Automation，并挂载兼容的 Apple 签名开发者镜像。镜像缺失 DisplayService 时，读取和启动可能成功，触控和文本仍可失败。[原生桥](https://github.com/JosssphZhou/poki/blob/d2837bf08357c82a6e3be415b83697601336f583/native/NATIVE.md) · [设备准备](https://github.com/JosssphZhou/poki/blob/d2837bf08357c82a6e3be415b83697601336f583/docs/physical-iphone.md) |
| 无线接入 | 初次信任之后可在局域网操作。跨网实验用保存的 RemotePairing 记录与 Tailscale，手机仍需解锁并保持可达。USB、局域网和跨网覆盖的管理操作不同，启动成功不推导安装或容器访问权限。[RemotePairing](https://github.com/JosssphZhou/poki/blob/d2837bf08357c82a6e3be415b83697601336f583/docs/remote-iphone.md) |
| Simulator 与 WDA | macOS Simulator 适配走本机 CoreSimulator 及模拟输入。WDA 是可选 computer-use 后端，需先有可访问的 WDA 测试服务，由 `POKI_CUA_BACKEND` 和 `POKI_WDA_URL` 显式选择。主物理设备桥独立使用 idevice。官方仓库目标是 macOS 和 iOS，Linux 是另维护的社区端口。[模拟器](https://github.com/JosssphZhou/poki/blob/d2837bf08357c82a6e3be415b83697601336f583/native/simulator.md) · [WDA](https://github.com/JosssphZhou/poki/blob/d2837bf08357c82a6e3be415b83697601336f583/src/cua-wda.mjs) |
| 任务回执 | `look` 同时取截图与 AX，AX 不可用时使用截图 OCR。`do` 把发出、未发出、可能已送达分开，动作后再读取。协调层支持设备租约和可选输入锁，页面引用和输入后的状态检查独立处理。上游实机覆盖限定为中文竖屏，记录还分别标明协议 fixture、模拟器和实机的证据范围。[CUA](https://github.com/JosssphZhou/poki/blob/d2837bf08357c82a6e3be415b83697601336f583/src/cua.mjs) · [输入锁](https://github.com/JosssphZhou/poki/blob/d2837bf08357c82a6e3be415b83697601336f583/src/input-lock.mjs) · [验收记录](https://github.com/JosssphZhou/poki/blob/d2837bf08357c82a6e3be415b83697601336f583/docs/verification.md) |

Rish 采用分级动作回执与观察超时的设计思路。桌面私有接口桥与 WDA 归入独立实验候选。普通 iOS 安装包的能力按公开 API 单独定义。Poki 原创代码为 AGPL-3.0-only，固定版本的 idevice 为 MIT，模拟器参考的 idb 声明和图像处理依赖各自保留许可。Rish 本轮未引入 Poki 代码、构建依赖或二进制。见 [LICENSE](https://github.com/JosssphZhou/poki/blob/d2837bf08357c82a6e3be415b83697601336f583/LICENSE)、[第三方声明](https://github.com/JosssphZhou/poki/blob/d2837bf08357c82a6e3be415b83697601336f583/THIRD_PARTY_NOTICES.md) 和 [依赖清单](https://github.com/JosssphZhou/poki/blob/d2837bf08357c82a6e3be415b83697601336f583/docs/third-party-dependencies.md)。
