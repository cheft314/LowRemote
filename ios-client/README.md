# LowRemote iOS 客户端

> 基于 Swift + SwiftUI 的 Mac 远程控制 iOS 端，与 `mac-server` 完全兼容。

## 功能特性

| 功能 | 状态 |
|------|------|
| mDNS 自动发现 Mac | ✅ |
| H.265 硬解视频流 | ✅ |
| 完整触控板手势（1-5指） | ✅ |
| 视频区绝对/相对触控模式 | ✅ |
| 快捷键面板（3行15键） | ✅ |
| 文字输入 → Mac | ✅ |
| Mac 系统音频 → iPhone | ✅ |
| iPhone 麦克风 → Mac | ✅ |
| 多显示器切换 | ✅ |
| 帧率切换（30/60/120fps） | ✅ |
| 文件传输到 Mac ~/Downloads | ✅ |
| iPad 外接键盘直通 | ✅ |
| Liquid Glass UI（iOS 17 模拟 / iOS 26 原生） | ✅ |
| iPhone 竖屏 + 横屏自适应布局 | ✅ |
| iPad 专属宽松布局 | ✅ |
| 已保存主机列表（增删改） | ✅ |
| 心跳保活 + 后台运行 | ✅ |

## 通信协议

与 Mac Server 完全对齐：

- **TCP 8890**：控制指令（FPS / PING / SCREEN / AUDIO_ON / FILE_START 等）
- **UDP 8891**：视频流（H.265 Annex-B 分片）/ 控制事件 / 音频 PCM

包头格式（10 字节 Little-Endian）：
```
[frame_id:4] [pkt_idx:2] [pkt_total:2] [type:1] [flags:1]
type: 0x01=视频 0x02=控制事件 0x03=麦克风音频 0x04=系统音频
```

## 项目结构

```
ios-client/
├── LowRemote.xcodeproj/        ← Xcode 项目文件
├── Package.swift               ← SPM 描述
└── LowRemote/
    ├── App/
    │   ├── LowRemoteApp.swift  ← @main + 权限引导 + 键盘桥接
    │   └── AppState.swift      ← 全局状态 @Observable
    ├── Model/
    │   ├── RemoteDevice.swift
    │   ├── ControlEvent.swift  ← 控制事件枚举 + serialize()
    │   ├── Packet.swift        ← UDP 包头编解码
    │   └── MacKeyCodes.swift   ← CGKeyCode 常量
    ├── Network/
    │   ├── MdnsDiscovery.swift ← NWBrowser
    │   ├── TcpClient.swift     ← NWConnection 行协议
    │   ├── UdpReceiver.swift   ← POSIX socket 接收
    │   └── UdpSender.swift     ← 共享 fd 发送
    ├── Codec/
    │   ├── FrameAssembler.swift ← UDP 分片重组
    │   ├── H265Decoder.swift    ← VideoToolbox VT 硬解
    │   └── VideoSurfaceView.swift ← AVSampleBufferDisplayLayer
    ├── Audio/
    │   ├── AudioPlayer.swift   ← Mac 系统音播放（Float32 48kHz）
    │   └── AudioCapture.swift  ← 麦克风录制（Int16 16kHz）
    ├── Session/
    │   ├── RemoteSession.swift ← 会话生命周期（@Observable）
    │   └── SavedHostsStore.swift ← 主机持久化
    └── UI/
        ├── Theme/
        │   ├── Colors.swift
        │   ├── Typography.swift
        │   └── LiquidGlassModifier.swift
        ├── DeviceListView.swift
        ├── RemoteView.swift
        ├── ShortcutKeyboardView.swift
        ├── SettingsPanelView.swift
        ├── FileTransferView.swift
        ├── PermissionGuideView.swift
        ├── TouchpadView.swift
        └── VideoTouchView.swift
```

## 系统要求

- iOS 17.0+（Liquid Glass 效果使用 Material 模拟）
- iOS 26.0+（启用系统原生 Liquid Glass API）
- iPhone / iPad 均支持

## 构建步骤

1. 用 Xcode 15+ 打开 `LowRemote.xcodeproj`
2. 选择目标设备（iPhone / iPad）
3. 配置 Signing（Team + Bundle ID）
4. Build & Run（需真机，模拟器无硬件解码）

## 注意事项

- 视频解码需真机（VideoToolbox 硬件解码模拟器不支持 HEVC）
- 首次运行需授权本地网络权限（系统弹窗）
- 麦克风权限为可选，仅在开启麦克风传输时需要
- Mac 端需提前运行 `mac-server`，并开放屏幕录制 + 辅助功能权限
