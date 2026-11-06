<p align="center">
  <img src="./brand/rish-readme-icon.svg" alt="Rish" width="96" />
</p>

<h1 align="center">Rish，你的口袋 Agent。</h1>

<p align="center"><a href="./README.md">English</a> · <b>简体中文</b> · <a href="./README.zh-TW.md">繁體中文</a> · <a href="./README.ja.md">日本語</a> · <a href="./README.ko.md">한국어</a> · <a href="./README.fr.md">Français</a> · <a href="./README.es.md">Español</a> · <a href="./README.de.md">Deutsch</a> · <a href="./README.pt.md">Português</a> · <a href="./README.ru.md">Русский</a> · <a href="./README.hi.md">हिन्दी</a> · <a href="./README.tr.md">Türkçe</a> · <a href="./README.th.md">ไทย</a> · <a href="./README.vi.md">Tiếng Việt</a> · <a href="./README.id.md">Bahasa Indonesia</a></p>

Rish 是面向对话与本地工作空间的实验性原生应用。界面使用 Rust 编写，
iOS/Android 使用 GPUI Mobile，macOS 预览使用 GPUI Fast。
当前仓库保留 GPUI 应用和原生运行时服务，原 React Native 应用已移除。

## 当前范围

- 共享 GPUI 界面：窄屏抽屉菜单、宽屏侧栏、明暗主题、Lucide 图标和中英文界面。
- 基础原生文本对话、会话保存、模型与思考强度设置，以及移动端原生消息编辑和命名表单。
- 新建文件夹和 UTF-8 文本文件，编辑并保存 256 KiB 以内的文本；保存校验原始版本，失败时保留草稿。
- 平台原生服务继续管理模型凭据、网络请求、工作空间文件、Git 和运行时。
  会话变更经过共享 Rust 校验器，以 generation/digest 比较交换保证持久化一致性。

目前仍是开发预览。**完整 Agent 控制器、工具执行流程、附件、完整设置和任务
Live Activity 集成尚未在 GPUI 界面中完成。** 原生接口存在不代表功能已经端到端可用；
旧应用的账号验证记录和截图也不代表 GPUI 版本已通过验收。

开发应用使用 `tech.zseven.rish.gpui`，拥有独立数据容器，不会自动迁移已安装旧应用的数据。
macOS 版本仅提供界面预览，不含手机运行时。GPUI 的 TestFlight 和签名发布流水线尚未验证。

## 从源码构建

在仓库根目录运行：

```sh
apps/gpui/scripts/check.sh core
apps/gpui/scripts/check.sh desktop
apps/gpui/scripts/build-desktop.sh --run
```

移动端需要先准备原生依赖。工具链、iOS 模拟器构建、Android APK 和测试入口见
[开发指南](docs/development.md)；共享源码与桥接结构见 [GPUI 指南](apps/gpui/README.md)；
已实现内容及待验证边界见 [迁移状态](docs/gpui-migration.md)。

## 架构

```text
GPUI 界面 → Rust 状态与控制器 → 原生 JSON 桥接
                                ├─ 模型服务与安全凭据存储
                                ├─ 会话与工作空间持久化
                                └─ 文件、Git 与运行时服务
```

模型请求会把所需对话和任务上下文发送给配置的服务。
本地文件与原生执行不等于离线模型推理；运行时能力由平台、已准备的依赖和构建配置决定。

| 目录 | 用途 |
| --- | --- |
| [`apps/gpui`](apps/gpui) | 共享 Rust 界面及 iOS/Android 原生宿主 |
| [`modules/rish/core`](modules/rish/core) | 共享会话与运行时规则 |
| [`modules/rish/ios`](modules/rish/ios) | Objective-C/Objective-C++ 服务与测试 |
| [`modules/rish/android`](modules/rish/android) | Kotlin/JNI 服务与原生依赖 |
| [`modules/rish/shared/GuestAssets`](modules/rish/shared/GuestAssets) | 共享 Guest 资源 |
| [`scripts`](scripts) | 原生依赖准备与源码检查 |

## 项目链接

- [贡献指南](CONTRIBUTING.md) · [开发指南](docs/development.md) · [发布状态](docs/testflight.md)
- [Rish 运行时](https://github.com/ZSeven-W/rish)
- [GPUI Mobile](https://github.com/itsbalamurali/gpui-mobile) · [GPUI Fast](https://github.com/longbridge/gpui-fast)
- [MIT 许可证](LICENSE) · [第三方声明](THIRD_PARTY_NOTICES.md)
