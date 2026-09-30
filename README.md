# JSM

<!-- dwgx-banner:BEGIN -->
<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/banner.svg?t=fcedd6628acc" />
  <source media="(prefers-color-scheme: light)" srcset="docs/assets/banner-light.svg?t=fcedd6628acc" />
  <img src="docs/assets/banner.svg?t=fcedd6628acc" width="100%" alt="JSM — Swift 编写的 macOS Java / Paper / Spigot 服务器管理器" />
</picture>

<br/>

Swift · MIT · ★12

[releases](https://github.com/dwgx/JSM/releases)

</div>
<!-- dwgx-banner:END -->


**macOS 原生 Minecraft 服务端管理工具** | **Native macOS Minecraft Server Manager**

---

## Overview

JSM is a SwiftUI desktop app for managing Java-based Minecraft servers (Paper / Spigot / Vanilla) on macOS. It puts everything in one window: create and import servers, start/stop/restart processes, watch live console output, monitor CPU and memory, switch themes, and import/export configuration bundles.

## 概述

JSM 是一个 SwiftUI 桌面应用，把 Java 版 Minecraft 服务端（Paper / Spigot / 原版）的日常操作集中到一个窗口：新建和导入服务器、启停和重启进程、实时控制台输出、CPU 和内存监控、主题切换、配置整包导入导出。

---

## Features

- Manage multiple server instances (import / create / edit)
- Start, stop, restart server processes with crash-restart policy (`restartOnCrash`, `maxRestarts`)
- Live console output via WebKit-based view (plus plain-text fallback)
- Runtime metrics: CPU %, resident memory, thread count (via `proc_pidinfo`)
- Import/export server configs and full bundles via YAML
- Auto-detect Java installations (Homebrew, SDKMAN, etc.)
- Theme engine with bundled packages (`JSM Default`, `CodexMono`), light/dark/system appearance
- Script editor and diagnostics report export

## 功能

- 多服务器实例管理（导入 / 新建 / 编辑）
- 启动、停止、重启进程，支持崩溃自动重启策略（`restartOnCrash`、`maxRestarts`）
- 实时控制台输出（基于 WebKit 的控制台视图 + 纯文本备用视图）
- 运行指标监控：CPU 占用、常驻内存、线程数（通过 `proc_pidinfo` 采样）
- 通过 YAML 导入/导出单个配置或整包（bundle）
- 自动探测 Java（Homebrew、SDKMAN 等常见位置）
- 主题引擎：内置主题包（`JSM Default`、`CodexMono`），浅色/深色/跟随系统
- 脚本编辑、诊断报告导出

---

## Tech Stack / 技术栈

| | |
|---|---|
| Language | Swift (SwiftUI, AppKit interop, WebKit) |
| Platform | macOS, App Sandbox enabled |
| Build | Xcode project `JSM.xcodeproj`, Swift 5.0, deployment target macOS 26.2 |
| Dependencies | [Yams](https://github.com/jpsim/Yams) 5.4.0 (YAML), [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) 0.9.20 (archive) |

<!-- TODO: confirm the intended minimum macOS version; the project file targets 26.2 -->
<!-- TODO: confirm whether oshi.properties (OSHI library) is actually used at runtime -->

---

## Project Structure / 项目结构

```
JSM/
├── JSM/
│   ├── JSMApp.swift            @main 入口 / app entry point
│   ├── ContentView.swift       根视图 -> MainWindow
│   ├── Core/
│   │   ├── App/                AppStore, AppSettings, ServerStore
│   │   ├── Config/             ConfigLoader (YAML read/write)
│   │   ├── ImportExport/       BundleExporter / BundleImporter
│   │   ├── Metrics/            MetricsProvider (process sampling)
│   │   ├── Process/            JavaLocator, ProcessController
│   │   ├── Server/             ServerModels
│   │   └── Theme/              ThemeEngine / ThemeLibrary / ThemeModels
│   ├── System/Security/        Bookmarking, Quarantine, SandboxAccess
│   ├── UI/
│   │   ├── Components/         ConsoleView, WebConsoleView, StatCard
│   │   ├── Pages/              HomePage, ServersPage, SettingsPage, ThemePage
│   │   ├── ThemeBinding/       ThemeBinder
│   │   └── Windows/            MainWindow (NavigationSplitView)
│   ├── Resources/Themes/       内置主题包 (.bundle)
│   └── Assets.xcassets/
├── Resources/_disabled_themes/
├── scripts/build_installer_dmg.sh
├── LICENSE
└── README.md
```

---

## Getting Started / 快速开始

### Requirements / 运行环境

- macOS (deployment target: 26.2)
- Java 17+ (recommended: Java 21)
- For building from source: Xcode 16+

<!-- TODO: confirm exact minimum Xcode version -->

### Install / 安装

1. Download `JSM-v*-Installer.dmg` from Releases / 从 Releases 下载安装 DMG
2. Drag `JSM.app` into `Applications` / 拖入应用程序文件夹
3. If Gatekeeper blocks first launch: right-click -> Open / 首次被拦截就右键打开

<!-- TODO: confirm a published Release / DMG exists -->

### Build from source / 从源码构建

Open `JSM.xcodeproj` in Xcode, select the `JSM` scheme, build and run. SwiftPM dependencies resolve automatically.

用 Xcode 打开 `JSM.xcodeproj`，选 `JSM` scheme 构建运行，SwiftPM 依赖会自动拉取。

Command line:

```bash
xcodebuild -project JSM.xcodeproj \
  -scheme JSM \
  -configuration Debug \
  -destination 'platform=macOS' build
```

Package installer DMG (requires a built `JSM.app`):

```bash
scripts/build_installer_dmg.sh -a /path/to/JSM.app -o /path/to/JSM-Installer.dmg -v "JSM Installer"
```

---

## Usage / 使用方法

- Server definitions are stored as YAML at `~/Library/Application Support/JSM/servers.yaml`.
  服务器定义以 YAML 保存在 `~/Library/Application Support/JSM/servers.yaml`。
- Three launch modes: jar, mainClass, or script.
  三种启动方式：jar 包、主类（mainClass）、脚本（script）。
- `Java Options` field takes JVM args only — don't paste a full `java -jar ...` line.
  `Java Options` 只填 JVM 参数，别把整条启动命令塞进去。
- First use may prompt you to authorize the Java Home directory (containing `bin/java`).
  首次使用可能需要授权 Java Home 目录。

---

## Configuration / 配置

App Sandbox enabled. Accesses user-selected directories via security-scoped bookmarks (`System/Security/`). Entitlements:

- User-selected file read-write, app-scope bookmarks
- Network client and server
- Read-only temporary exceptions for common Java paths: `~/.sdkman/candidates/java/`, `/opt/homebrew/`, `/usr/local/`, `/opt/local/`

Server config fields (`ServerConfig` / `ServerDefinition`): `name`, `type`, `entry` (jar/mainClass/script), `javaOptions`, `programArgs`, `env` (environment variable map), `lifecycle` (`restartOnCrash` / `maxRestarts` / `stopSignal`).

---

## Status / 状态

Personal project, `MARKETING_VERSION = 1.0`. Functional and evolving — interfaces and config formats may change.

个人项目，版本 1.0。功能可用，持续演进中，接口和配置格式可能变动。

<!-- TODO: confirm current maturity/roadmap -->

---

## License / 许可证

MIT License — Copyright (c) 2026 dwgx. See [`LICENSE`](LICENSE).
