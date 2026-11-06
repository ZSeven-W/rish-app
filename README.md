<p align="center">
  <img src="./brand/rish-readme-icon.svg" alt="Rish" width="96" />
</p>

<h1 align="center">Rish, your pocket agent.</h1>

<p align="center"><b>English</b> · <a href="./README.zh.md">简体中文</a> · <a href="./README.zh-TW.md">繁體中文</a> · <a href="./README.ja.md">日本語</a> · <a href="./README.ko.md">한국어</a> · <a href="./README.fr.md">Français</a> · <a href="./README.es.md">Español</a> · <a href="./README.de.md">Deutsch</a> · <a href="./README.pt.md">Português</a> · <a href="./README.ru.md">Русский</a> · <a href="./README.hi.md">हिन्दी</a> · <a href="./README.tr.md">Türkçe</a> · <a href="./README.th.md">ไทย</a> · <a href="./README.vi.md">Tiếng Việt</a> · <a href="./README.id.md">Bahasa Indonesia</a></p>

Rish is an experimental native app for conversations and local workspaces. Its
interface is written in Rust with GPUI Mobile on iOS/Android and GPUI Fast for
the macOS preview. The repository now contains the GPUI app and its native
runtime services; the previous React Native application has been removed.

## Current scope

- Shared GPUI interface with a compact navigation drawer, a wide-window sidebar,
  light/dark themes, Lucide icons, and English/Chinese UI strings.
- Basic native text chat, saved conversations, model/reasoning configuration,
  and native message/name editors on mobile.
- Provider-owned model catalogs fetched from the configured service or entered
  manually, with no bundled model choices or automatic fallback model.
- Create folders and UTF-8 text files, and edit files up to 256 KiB in the
  native editor. Saves check the original revision; failed saves retain a draft.
- Native platform services retain ownership of provider credentials, network
  calls, workspace files, Git, and runtime execution. Session mutations use the
  shared Rust validator and generation/digest compare-and-swap.

This is a development preview. **The full Agent controller and tool workflows,
attachments, complete settings, and task Live Activity integration are not yet
complete in the GPUI interface.** An exported native method is not evidence of
an end-to-end working feature. Existing account/provider verification and
screenshots from the old app do not establish GPUI acceptance.

The development app uses `tech.zseven.rish.gpui` and its own data container.
Previously installed apps and their data are not automatically migrated.
The macOS build is a UI preview without the mobile runtime. There is no verified
GPUI TestFlight or signed release pipeline yet.

## Build from source

Run from the repository root:

```sh
apps/gpui/scripts/check.sh core
apps/gpui/scripts/check.sh desktop
apps/gpui/scripts/build-desktop.sh --run
```

Mobile builds require explicitly prepared native dependencies. Follow the
[developer guide](docs/development.md) for toolchains, iOS simulator builds,
Android APKs, and tests. The [GPUI guide](apps/gpui/README.md) describes the shared
source layout and host bridge. The [migration status](docs/gpui-migration.md)
separates implemented code from validation still required.

Next milestones and the fini handoff are tracked in the [Mobile Agent roadmap](ROADMAP.md).

## Architecture

```text
GPUI views → Rust shell/controller → native JSON bridge
                                      ├─ provider and secure-storage services
                                      ├─ persisted sessions and workspaces
                                      └─ native file, Git and runtime services
```

Model requests send conversation/task context to the configured service.
Local files and native execution do not imply offline model inference. Runtime
availability depends on the platform, prepared artifacts, and enabled build
capabilities.

| Location | Purpose |
| --- | --- |
| [`apps/gpui`](apps/gpui) | Shared Rust UI and native iOS/Android hosts |
| [`modules/rish/core`](modules/rish/core) | Shared session and runtime rules |
| [`modules/rish/ios`](modules/rish/ios) | Objective-C/Objective-C++ services and tests |
| [`modules/rish/android`](modules/rish/android) | Kotlin/JNI services and native dependencies |
| [`modules/rish/shared/GuestAssets`](modules/rish/shared/GuestAssets) | Shared guest resources |
| [`scripts`](scripts) | Native dependency preparation and source checks |

## Project links

- [Contributing](CONTRIBUTING.md) · [Development](docs/development.md) · [Distribution status](docs/testflight.md)
- [Rish runtime](https://github.com/ZSeven-W/rish)
- [GPUI Mobile](https://github.com/itsbalamurali/gpui-mobile) · [GPUI Fast](https://github.com/longbridge/gpui-fast)
- [MIT License](LICENSE) · [Third-party notices](THIRD_PARTY_NOTICES.md)
