# JSM

JSM 是一个原生 macOS Java 服务器管理工具（如 Paper/Spigot），提供控制台、运行监控、配置导入导出和主题系统。

## 主要功能

- 多服务器管理：新建、导入、编辑、启动、停止、重启、强制结束
- 原生控制台与 Web 控制台双渲染
- 实时指标：CPU、内存、线程、文件描述符
- YAML 配置导入导出、整包导出
- 主题实时预览、保存和重置
- Java 运行时检测与诊断

## 环境要求

- macOS
- Java 17+（推荐 Java 21）
- 开发环境需 Xcode 16+

## 普通用户使用（默认）

1. 在 Release 页面下载 `JSM-v*-Installer.dmg`
2. 打开 DMG，把 `JSM.app` 拖到 `Applications`
3. 从“应用程序”启动 JSM
4. 在“服务器”页导入你的服务器目录，或新建服务器
5. 在“Java Options”里只填 JVM 参数，不要填 `java -jar ...`

## 首次打开提示“无法验证”处理

当前公开包如果未做 Apple 公证，macOS 可能显示“无法验证开发者”。可用以下方式打开：

1. 在 Finder 中右键 `JSM.app` -> “打开”
2. 系统弹窗中再次点“打开”

## 开发构建

```bash
xcodebuild -project /Users/dwgx/Documents/Project/JSM/JSM.xcodeproj \
  -scheme JSM \
  -configuration Debug \
  -destination 'platform=macOS' build
```

## 生成安装 DMG

```bash
xcodebuild -project /Users/dwgx/Documents/Project/JSM/JSM.xcodeproj \
  -scheme JSM \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/JSMRelease build

/Users/dwgx/Documents/Project/JSM/scripts/build_installer_dmg.sh \
  -a /tmp/JSMRelease/Build/Products/Release/JSM.app \
  -o /Users/dwgx/Desktop/JSM-Installer.dmg
```

## 项目结构

- `/Users/dwgx/Documents/Project/JSM/JSM/Core`：核心逻辑（进程、配置、指标、主题）
- `/Users/dwgx/Documents/Project/JSM/JSM/UI`：界面页面与组件
- `/Users/dwgx/Documents/Project/JSM/JSM/System`：系统权限与安全辅助
- `/Users/dwgx/Documents/Project/JSM/JSM/Resources`：内置主题与资源

## License

MIT，详见 `LICENSE`。
