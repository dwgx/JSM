# JSM

JSM 是一个原生 macOS 的 Java 服务器管理工具（偏向 Paper/Spigot 这类服务端）。

一句话总结：
你可以在一个桌面应用里完成服务器导入、启动停止、控制台查看、主题切换和基础状态监控。

## 能做什么

- 管理多个服务器实例（导入/新建/编辑）
- 启停和重启服务器进程
- 查看运行控制台输出
- 查看 CPU、内存等运行指标
- 导入导出配置和整包
- 主题切换与重置

## 运行环境

- macOS
- Java 17+（推荐 Java 21）
- 开发构建建议 Xcode 16+

## 普通用户安装

1. 到 Releases 下载 `JSM-v*-Installer.dmg`
2. 把 `JSM.app` 拖进 `Applications`
3. 首次打开若被拦截：在 Finder 里右键应用 -> 打开

## 开发构建（示例）

```bash
xcodebuild -project JSM.xcodeproj \
  -scheme JSM \
  -configuration Debug \
  -destination 'platform=macOS' build
```

## 目录说明

- `JSM/Core`：进程管理、配置、指标等核心逻辑
- `JSM/UI`：界面层
- `JSM/System`：系统权限与底层辅助
- `Resources`：资源文件
- `scripts`：打包和辅助脚本

## 使用提示

- Java Options 里填 JVM 参数，不要把 `java -jar ...` 整行塞进去
- 建议先在测试服务器验证参数，再上正式服

## License

MIT
