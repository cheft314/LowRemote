# LowRemote

局域网 Mac 远程控制 MVP — Mac 被控端（Swift）+ Android 控制端（Kotlin）

> 极致低延迟、H.265 硬编硬解、30/60/120fps 可切换、纯局域网无需外网、无加密无配对。

## 仓库结构

```
LowRemote/
├── docs/                    # 技术规格文档
├── mac-server/              # Mac 被控端（Swift Package）
│   ├── Package.swift
│   └── Sources/
│       └── MacRemoteServer/
│           ├── main.swift
│           ├── AppDelegate.swift
│           ├── Network/
│           ├── Capture/
│           ├── Input/
│           └── Models/
└── android-client/          # Android 控制端（Gradle + Kotlin + Compose）
    ├── settings.gradle.kts
    ├── build.gradle.kts
    ├── gradle.properties
    └── app/
        ├── build.gradle.kts
        └── src/main/
            ├── AndroidManifest.xml
            ├── kotlin/com/lowremote/
            └── res/
```

## 如何运行

### Mac 被控端

需要 macOS 13+，Xcode 15+ 或 Swift 5.9+ 命令行工具。

```bash
cd mac-server
swift run MacRemoteServer
```

首次运行系统会提示：
1. **屏幕录制权限** → 系统设置 → 隐私与安全 → 屏幕录制，勾选 Terminal（或打包后的 app）
2. **辅助功能权限** → 系统设置 → 隐私与安全 → 辅助功能，勾选 Terminal（或 app）

菜单栏会出现一个图标，显示当前连接状态。

### Android 控制端

需要 Android Studio Iguana+、Android 11 (API 30)+ 设备。

```bash
cd android-client
./gradlew installDebug
```

确保手机和 Mac 在同一局域网。启动 app 后会自动发现 Mac 设备。

## 端口约定

| 端口 | 协议 | 用途 |
|------|------|------|
| 8890 | TCP | 控制指令（FPS、心跳、断连） |
| 8891 | UDP | 视频流 + 键鼠事件 |
| mDNS | — | 服务类型 `_maclocalremote._tcp` |

## 性能目标

- 局域网端到端延迟 < 100ms
- 120fps 流畅运行
- Mac 推流 CPU < 15%（硬编保证）

详细设计参见 [docs/LowRemote_MVP_Technical_Spec.md](docs/LowRemote_MVP_Technical_Spec.md)。
