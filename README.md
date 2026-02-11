# JSM

JSM is a native macOS app for managing Java servers (for example Paper/Spigot) with built-in console, runtime metrics, YAML config editing, and theme customization.

## Features

- Multi-server management: create/import/edit/start/stop/restart/force-stop servers
- Native and Web console renderers
- Real-time server metrics: CPU, RAM, thread count, file descriptors
- YAML-based server config import/export and bundle export
- Theme engine with live preview and version history
- Java runtime detection, authorization, and diagnostics for sandbox environments

## Requirements

- macOS
- Xcode 16+
- Swift 5
- Java 17+ (Java 21 recommended for modern Paper builds)

## Build

```bash
xcodebuild -project /Users/dwgx/Documents/Project/JSM/JSM.xcodeproj \
  -scheme JSM \
  -configuration Debug \
  -destination 'platform=macOS' build
```

## Run in Xcode

1. Open `/Users/dwgx/Documents/Project/JSM/JSM.xcodeproj`
2. Select scheme `JSM`
3. Run (`Cmd + R`)

## Project Layout

- `/Users/dwgx/Documents/Project/JSM/JSM/Core` core logic (app store, process, metrics, config, theme)
- `/Users/dwgx/Documents/Project/JSM/JSM/UI` pages/components/windows
- `/Users/dwgx/Documents/Project/JSM/JSM/System` sandbox/security helpers
- `/Users/dwgx/Documents/Project/JSM/JSM/Resources` built-in themes

## License

This project is licensed under the MIT License. See `LICENSE`.

