# LowRemote MVP 技术规格文档

> 版本：v1.1 | 日期：2026-05-10 | 状态：AI 开发指导文档
> 变更：控制端由 Flutter 改为 Android 原生（Kotlin），iOS 端后续迭代实现

---

## 一、项目概览

| 属性 | 说明 |
|------|------|
| 项目名 | LowRemote |
| 目标 | 局域网 Mac 远程控制，极致低延迟，最小可用 MVP |
| 被控端 | Mac (Swift 原生) |
| 控制端 | **Android 原生（Kotlin）**，MVP 阶段仅实现 Android |
| iOS 端 | 后续迭代实现，本文档暂不涉及 |
| 网络环境 | 纯局域网，无需外网，无加密，无配对 |
| 视频编码 | H.265 (HEVC) 硬编硬解，不降级 H.264 |
| 帧率档位 | 30 / 60 / 120 fps 三档可选 |
| 核心原则 | 极简架构、低延迟优先、最小功能集、全程零拷贝视频路径 |

---

## 二、整体架构

### 2.1 网络拓扑

```
┌─────────────────────────────────────────────────────┐
│                   局域网 (LAN)                        │
│                                                     │
│  ┌─────────────────┐        ┌──────────────────┐   │
│  │   Mac 被控端     │        │  Android 控制端   │   │
│  │   (Swift)       │        │  (Kotlin 原生)   │   │
│  │                 │        │                  │   │
│  │  mDNS 广播 ───────────────→ mDNS 扫描发现    │   │
│  │                 │        │                  │   │
│  │  TCP :8890 ←────────────── TCP 控制指令      │   │
│  │  (控制通道)      │        │  (帧率/心跳/断连) │   │
│  │                 │        │                  │   │
│  │  UDP :8891 ─────────────→ H.265 视频流       │   │
│  │  (数据通道)  ←────────────  键鼠事件          │   │
│  └─────────────────┘        └──────────────────┘   │
└─────────────────────────────────────────────────────┘
```

### 2.2 数据流

1. Mac 启动 → 注册 mDNS 服务 + 监听 TCP 8890 / UDP 8891
2. Android 端 mDNS 扫描 → 展示设备列表
3. 用户点击设备 → 建立 TCP + UDP 双通道连接
4. Android 通过 TCP 下发帧率指令（FPS:30/60/120）
5. Mac 按设定帧率 H.265 硬编屏幕 → UDP 持续推流到 Android
6. Android UDP 收流（DatagramChannel）→ MediaCodec 硬解码 → SurfaceView 渲染（全程零拷贝）
7. 用户触控板 / 快捷键操作 → UDP 事件包 → Mac CGEvent 模拟注入

---

## 三、Mac 被控端（Swift）

### 3.1 技术栈

| 模块 | 技术选型 |
|------|---------|
| 语言 | Swift 5.9+ |
| 屏幕捕获 | `CGDisplayStream` + `IOSurface` 硬件捕获 |
| 视频编码 | `VideoToolbox` HEVC (H.265) 硬编码 |
| 网络 | `Network.framework`（NWListener / NWConnection） |
| mDNS 注册 | `NetService`（Foundation）注册 `_maclocalremote._tcp` |
| 键鼠模拟 | `CGEvent` + `CGEventPost` |
| UI | MenuBar App（`NSStatusItem`），无主窗口 |

### 3.2 模块划分

```
MacRemoteServer/
├── AppDelegate.swift          # 菜单栏入口，权限检测，服务生命周期
├── Network/
│   ├── BonjourAdvertiser.swift    # mDNS 服务注册
│   ├── TCPServer.swift            # TCP 控制通道服务器
│   └── UDPServer.swift            # UDP 数据通道（收发复用）
├── Capture/
│   ├── ScreenCaptureManager.swift # CGDisplayStream 屏幕捕获
│   └── VideoEncoder.swift         # VideoToolbox H.265 硬编
├── Input/
│   └── InputSimulator.swift       # CGEvent 键鼠事件注入
└── Models/
    └── ControlEvent.swift         # 控制事件数据模型
```

### 3.3 mDNS 服务注册

- 服务类型：`_maclocalremote._tcp.`
- 服务名：Mac 设备名称（`Host.current().localizedName`）
- TXT Record 附加字段：
  - `tcp_port=8890`
  - `udp_port=8891`
  - `device=<MacName>`
- 实现类：`NetService`（Foundation 框架），**不使用** `NWBrowser`（仅作客户端）

### 3.4 屏幕捕获与 H.265 编码

**捕获流程：**
```
CGDisplayStream(主显示器, 目标帧率)
    → IOSurface 回调（每帧）
    → CVPixelBuffer 包装
    → VideoToolbox VTCompressionSession (H.265 硬编)
    → CMSampleBuffer → 提取 NAL Units
    → UDP 分片发送
```

**VideoToolbox 编码关键参数：**
| 参数 | 值 |
|------|-----|
| 编码器 | `kCMVideoCodecType_HEVC` |
| Profile | Main |
| 实时模式 | `kVTCompressionPropertyKey_RealTime = true` |
| 最大关键帧间隔 | 60 帧（约 2 秒一个 IDR） |
| 允许帧重排序 | `false`（降低延迟） |
| 码率控制 | CBR，按帧率自适应（参考下表） |

**码率参考（自适应）：**
| 帧率 | 推荐码率 |
|------|---------|
| 30fps | 8 Mbps |
| 60fps | 15 Mbps |
| 120fps | 25 Mbps |

### 3.5 UDP 视频推流

**分片策略：**
- 最大包大小：1400 字节（避免 IP 分片，MTU 安全值）
- 帧头格式（8 字节）：

```
┌────────────┬──────────┬──────────┬──────────┐
│ frame_id   │ pkt_idx  │ pkt_total│ type     │
│ (uint32)   │ (uint16) │ (uint16) │ (uint8)  │
└────────────┴──────────┴──────────┴──────────┘
  4 bytes      2 bytes    2 bytes    1 byte
  
type: 0x01 = 视频帧分片, 0x02 = 控制事件
```

- 不做丢包重传，不做 FEC，追求最低延迟
- IDR 帧（关键帧）优先保证发送完整性，可重发 1 次

### 3.6 键鼠事件接收与模拟

**事件格式解析（UDP type=0x02）：**

| 事件类型 | 格式 | 说明 |
|---------|------|------|
| 鼠标移动 | `M:dx,dy` | dx/dy 为像素级相对位移（delta 模式） |
| 鼠标左键点击 | `MC:L` | Left Click |
| 鼠标右键点击 | `MC:R` | Right Click |
| 鼠标左键按下 | `MD:L` | Left Down（拖拽开始） |
| 鼠标左键释放 | `MU:L` | Left Up（拖拽结束） |
| 鼠标滚轮 | `MW:dy` | dy 为整数，正=上滚，负=下滚 |
| 键盘普通键 | `K:keyCode` | CGKeyCode 值 |
| 键盘组合键 | `KC:mod,keyCode` | mod: cmd/ctrl/alt/shift |
| 输入文字 | `T:text` | 直接注入 Unicode 字符串 |

**CGEvent 注入（delta 模式鼠标移动）：**
```swift
// 鼠标移动：delta 模式，在当前光标位置基础上累加偏移
let currentPos = CGEvent(source: nil)?.location ?? .zero
let newPoint = CGPoint(
    x: currentPos.x + dx,
    y: currentPos.y + dy
)
let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                    mouseCursorPosition: newPoint, mouseButton: .left)
event?.post(tap: .cghidEventTap)
```

### 3.7 心跳与断连管理

- TCP 心跳：每 30 秒发送 `PING`，对端回 `PONG`
- 超时 90 秒未收到心跳 → 视为断连
- 断连后：停止 `CGDisplayStream`，释放 `VTCompressionSession`，菜单栏图标更新

### 3.8 菜单栏 UI

```
[🖥️] LowRemote
├── 状态：已连接 / 等待连接
├── ────────────
├── 帧率：当前 60fps
├── ────────────
├── 停止服务
└── 退出
```

### 3.9 权限引导

启动时检测并引导（缺一不可）：
1. **屏幕录制权限**：`CGRequestScreenCaptureAccess()`
2. **辅助功能权限**：`AXIsProcessTrustedWithOptions()`

---

## 四、Android 控制端（Kotlin 原生）

> **架构决策**：采用纯 Android 原生方案（Kotlin），放弃 Flutter。
> 核心原因：视频路径全程零拷贝（`DatagramChannel` → `MediaCodec` → `SurfaceView`），
> 无任何跨层传递开销，是实现 120fps 极致低延迟的最优路径。

### 4.1 技术栈

| 模块 | 技术选型 | 说明 |
|------|---------|------|
| 语言 | Kotlin（协程 + Flow） | 主语言 |
| UI 框架 | Jetpack Compose | 现代声明式 UI |
| 视频渲染 | `SurfaceView` | 独立渲染线程，延迟最低 |
| H.265 硬解码 | `MediaCodec`（异步回调模式） | 硬解，直输 Surface |
| UDP 接收 | `DatagramChannel`（NIO 非阻塞） | 独立 IO 线程，零拷贝 |
| TCP 控制 | `Socket`（Kotlin 协程封装） | 控制指令通道 |
| mDNS 发现 | `NsdManager`（Android 原生） | 扫描 `_maclocalremote._tcp` |
| 手势识别 | 自定义 `GestureDetector` + 多指追踪 | 触控板手势状态机 |
| 最低 API | API 30（Android 11）| `KEY_LOW_LATENCY` 需要 API 30+ |

### 4.2 模块划分

```
android-remote-client/
└── app/src/main/
    ├── kotlin/com/lowremote/
    │   ├── MainActivity.kt                 # 入口，强制横屏，全屏
    │   ├── ui/
    │   │   ├── DeviceListScreen.kt         # Compose：设备发现列表页
    │   │   ├── RemoteScreen.kt             # Compose：主控制页（三区布局）
    │   │   ├── VideoSurfaceView.kt         # SurfaceView 视频渲染区
    │   │   ├── TouchpadView.kt             # 自定义 View：触控板区域
    │   │   └── ShortcutKeyboard.kt         # Compose：快捷键+输入区
    │   ├── session/
    │   │   └── RemoteSession.kt            # 会话生命周期管理
    │   ├── network/
    │   │   ├── MdnsDiscovery.kt            # NsdManager mDNS 扫描
    │   │   ├── TcpClient.kt                # TCP 控制通道（协程）
    │   │   ├── UdpReceiver.kt              # DatagramChannel 接收视频流
    │   │   └── UdpSender.kt                # DatagramSocket 发送控制事件
    │   ├── codec/
    │   │   ├── FrameAssembler.kt           # UDP 分片重组 → 完整 NAL
    │   │   └── H265Decoder.kt              # MediaCodec 异步硬解码
    │   └── model/
    │       ├── RemoteDevice.kt             # 设备信息数据类
    │       └── ControlEvent.kt             # 控制事件数据类
    └── res/
        └── layout/
            └── activity_main.xml           # 根布局容器
```

### 4.3 视频接收与解码（零拷贝关键路径）

**完整零拷贝链路：**
```
DatagramChannel(独立IO线程)
    → ByteBuffer 直接内存（Direct Buffer）
    → FrameAssembler 帧重组
    → MediaCodec.queueInputBuffer()  ← NAL 数据直接写入 codec buffer
    → MediaCodec 硬件解码
    → Surface(SurfaceView)           ← GPU 直接输出，不经 CPU
```

**H265Decoder.kt 关键配置：**
```kotlin
val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, width, height).apply {
    // 低延迟模式（API 30+，关闭解码器内部缓冲队列）
    setInteger("low-latency", 1)
    // 告知解码器运行帧率，让硬件调度器优化
    setFloat(MediaFormat.KEY_OPERATING_RATE, 120f)
    // 关闭 B 帧重排序，降低解码延迟
    setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
    // 优先级：0 = 实时，1 = 非实时
    setInteger(MediaFormat.KEY_PRIORITY, 0)
}

// 异步回调模式（比同步 dequeueOutputBuffer 延迟更低）
codec.setCallback(object : MediaCodec.Callback() {
    override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
        // 从 FrameAssembler 取一帧 NAL，写入 codec inputBuffer
        val buffer = codec.getInputBuffer(index) ?: return
        val nalData = frameAssembler.poll() ?: return
        buffer.put(nalData)
        codec.queueInputBuffer(index, 0, nalData.size, presentationTimeUs, flags)
    }
    override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
        // 直接渲染到 Surface，releaseOutputBuffer(render=true) 触发 GPU 合成
        codec.releaseOutputBuffer(index, true)
    }
    override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) { /* 重建解码器 */ }
    override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) { /* 解析分辨率 */ }
})

// 输出直连 SurfaceView 的 Surface，全程不经 CPU
codec.configure(format, surfaceView.holder.surface, null, 0)
codec.start()
```

**UdpReceiver.kt 关键配置：**
```kotlin
// NIO DatagramChannel，比 DatagramSocket 减少一次内存拷贝
val channel = DatagramChannel.open().apply {
    socket().reuseAddress = true
    socket().receiveBufferSize = 4 * 1024 * 1024  // 4MB 接收缓冲区
    socket().bind(InetSocketAddress(8891))
    configureBlocking(true)
}

// 直接内存 ByteBuffer，避免 JVM 堆拷贝
val buf = ByteBuffer.allocateDirect(65536)

// 独立线程循环接收
thread(name = "udp-receiver", priority = Thread.MAX_PRIORITY) {
    while (running) {
        buf.clear()
        channel.receive(buf)
        buf.flip()
        packetDispatcher.dispatch(buf)  // 解析包头，分发到 FrameAssembler 或 EventHandler
    }
}
```

### 4.4 帧重组器（FrameAssembler.kt）

```kotlin
// 以 frame_id 为 key，收集同一帧的所有分片
// 120fps 时每帧时间窗口 = 8ms，超时即丢弃不完整帧
class FrameAssembler(private val timeoutMs: Long = 8) {
    private val frames = ConcurrentHashMap<Int, FrameBuffer>()

    fun onPacket(frameId: Int, pktIdx: Int, pktTotal: Int, data: ByteArray) {
        val buf = frames.getOrPut(frameId) { FrameBuffer(pktTotal, System.currentTimeMillis()) }
        buf.put(pktIdx, data)
        if (buf.isComplete()) {
            frames.remove(frameId)
            decoderQueue.offer(buf.assemble())  // 送入解码队列
        }
    }

    fun evictExpired() {
        val now = System.currentTimeMillis()
        frames.entries.removeIf { now - it.value.createdAt > timeoutMs }
    }
}
```

### 4.5 固定 UI 布局规范

**强制横屏全屏（AndroidManifest.xml）：**
```xml
<activity
    android:screenOrientation="landscape"
    android:windowSoftInputMode="adjustNothing"
    android:theme="@style/Theme.LowRemote.Fullscreen" />
```

**三区布局（Compose）：**
```kotlin
// 整屏横向分为左 60% 视频 + 右 40% 控制
Row(modifier = Modifier.fillMaxSize()) {

    // ① 左侧：SurfaceView 视频区（60% 宽）
    // SurfaceView 不能直接嵌入 Compose，用 AndroidView 包装
    AndroidView(
        factory = { VideoSurfaceView(it) },
        modifier = Modifier
            .fillMaxHeight()
            .weight(0.6f)
    )

    // ② 右侧：控制区（40% 宽），上下分割
    Column(
        modifier = Modifier
            .fillMaxHeight()
            .weight(0.4f)
    ) {
        // 右上 45%：快捷键 + 文字输入
        ShortcutKeyboard(
            modifier = Modifier.weight(0.45f).fillMaxWidth(),
            onEvent = { session.sendEvent(it) }
        )
        // 右下 55%：触控板
        AndroidView(
            factory = { TouchpadView(it) },
            modifier = Modifier.weight(0.55f).fillMaxWidth()
        )
    }
}
```

**布局示意图：**
```
┌─────────────────────────────────────────────────────────┐
│                    横屏全屏布局                            │
│  ┌──────────────────────┐  ┌──────────────────────────┐ │
│  │                      │  │  右上角：快捷键 + 键盘区   │ │
│  │                      │  │  ┌──┐┌──┐┌──┐┌──┐┌──┐   │ │
│  │   左侧：SurfaceView  │  │  │⌘C││⌘V││⌘Z││⌘X││ESC│  │ │
│  │   视频渲染区          │  │  └──┘└──┘└──┘└──┘└──┘   │ │
│  │   16:10 比例黑边适配  │  │  ┌──┐┌──┐┌──┐┌──┐        │ │
│  │   MediaCodec 直输    │  │  │⌘↹││⌘⎵││⏎ ││⌫ │        │ │
│  │                      │  │  └──┘└──┘└──┘└──┘        │ │
│  │   约占总宽 60%        │  │  [ 文字输入框 → 发送 ]    │ │
│  │                      │  ├──────────────────────────┤ │
│  │                      │  │  右下角：触控板区域        │ │
│  │                      │  │  自定义 TouchpadView      │ │
│  │                      │  │  单指移动/点击/拖拽        │ │
│  │                      │  │  双指右键/滚轮             │ │
│  └──────────────────────┘  └──────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
  ← weight=0.6 →              ← weight=0.4 →
```

**16:10 视频比例黑边适配（VideoSurfaceView.kt）：**
```kotlin
override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
    val availW = MeasureSpec.getSize(widthMeasureSpec)
    val availH = MeasureSpec.getSize(heightMeasureSpec)
    // 在可用区域内保持 16:10 比例居中，多余部分留黑边
    val targetW: Int
    val targetH: Int
    if (availW * 10 > availH * 16) {
        targetH = availH
        targetW = availH * 16 / 10
    } else {
        targetW = availW
        targetH = availW * 10 / 16
    }
    setMeasuredDimension(targetW, targetH)
}
```

### 4.6 mDNS 设备发现（NsdManager）

```kotlin
class MdnsDiscovery(private val context: Context) {
    private val nsdManager = context.getSystemService(NsdManager::class.java)

    fun startDiscovery(onFound: (RemoteDevice) -> Unit) {
        nsdManager.discoverServices(
            "_maclocalremote._tcp",
            NsdManager.PROTOCOL_DNS_SD,
            object : NsdManager.DiscoveryListener {
                override fun onServiceFound(info: NsdServiceInfo) {
                    // 解析 TXT Record 获取 tcp_port / udp_port / device 名
                    nsdManager.resolveService(info, resolveListener(onFound))
                }
                // ... 其他回调
            }
        )
    }
}
```

### 4.7 触控板手势识别（TouchpadView.kt）

**手势状态机（自定义 View + MotionEvent 多指追踪）：**

| 手势 | 触发条件 | 发送事件 |
|------|---------|---------|
| 单指滑动 | 1 指 MOVE，位移 > 3dp | `M:normX,normY`（delta 模式） |
| 单指轻点 | 1 指 UP，耗时 < 200ms，位移 < 5dp | `MC:L` |
| 单指长按滑动 | 1 指按住 > 500ms 后 MOVE | `MD:L` → `M:x,y`... → `MU:L` |
| 双指轻点 | 2 指同时 UP，耗时 < 200ms | `MC:R` |
| 双指垂直滑动 | 2 指 MOVE，纵向为主方向 | `MW:dy`（累积 dy / 滚动系数） |

```kotlin
// 坐标使用 delta 模式（相对位移），而非绝对归一化
// 原因：delta 模式对鼠标灵敏度控制更自然，且不依赖触控板和屏幕比例
private var lastX = 0f
private var lastY = 0f
private val sensitivity = 1.8f  // 默认灵敏度系数

override fun onTouchEvent(event: MotionEvent): Boolean {
    when (event.actionMasked) {
        MotionEvent.ACTION_MOVE -> {
            if (event.pointerCount == 1) {
                val dx = (event.x - lastX) * sensitivity
                val dy = (event.y - lastY) * sensitivity
                udpSender.send("M:${dx.format()},${dy.format()}")
            }
        }
        // ...
    }
    lastX = event.x; lastY = event.y
    return true
}
```

> **注意**：鼠标移动改为 **delta 模式**（发送相对位移 dx/dy），Mac 端收到后累加到当前鼠标位置。
> 相比归一化绝对坐标，delta 模式手感更接近真实触控板，灵敏度也更易调节。

### 4.8 快捷键定义

| 按钮标签 | 发送事件 | 说明 |
|---------|---------|------|
| ⌘C | `KC:cmd,8` | 复制 |
| ⌘V | `KC:cmd,9` | 粘贴 |
| ⌘Z | `KC:cmd,6` | 撤销 |
| ⌘X | `KC:cmd,7` | 剪切 |
| ⌘Tab | `KC:cmd,48` | 切换应用 |
| ⌘Space | `KC:cmd,49` | Spotlight |
| ESC | `K:53` | 退出/取消 |
| Return | `K:36` | 回车 |
| Delete | `K:51` | 退格 |

> 键码基于 macOS CGKeyCode 标准定义

### 4.9 文字输入

```kotlin
// EditText 捕获输入，每次文字变化提取 diff，发送 T: 指令
// 使用隐藏的 EditText 弹出系统键盘，输入完成点发送
binding.inputField.addTextChangedListener { text ->
    val input = text.toString()
    if (input.isNotEmpty()) {
        udpSender.send("T:$input")
        binding.inputField.setText("")
    }
}
```

---

## 五、通信协议规范

### 5.1 TCP 控制通道（端口 8890）

- 连接方：Android → Mac
- 编码：UTF-8 文本行（`\n` 结尾）
- 无需加密、无需握手

| 指令 | 方向 | 说明 |
|------|------|------|
| `FPS:30\n` | Android→Mac | 设置 30fps |
| `FPS:60\n` | Android→Mac | 设置 60fps |
| `FPS:120\n` | Android→Mac | 设置 120fps |
| `PING\n` | 双向 | 心跳请求 |
| `PONG\n` | 双向 | 心跳响应 |
| `DISCONNECT\n` | Android→Mac | 主动断开 |
| `OK\n` | Mac→Android | 指令确认 |
| `RESOLUTION:W,H\n` | Mac→Android | 握手时通知屏幕分辨率 |

**连接握手序列：**
```
Android → Mac : TCP 连接
Mac → Android : RESOLUTION:2560,1600\n   (通知分辨率)
Android → Mac : FPS:60\n                 (设置帧率)
Mac → Android : OK\n                     (确认，开始推流)
```

### 5.2 UDP 数据通道（端口 8891）

**通用包头（8 字节）：**
```
┌──────────────┬────────────┬────────────┬──────────┐
│  frame_id    │  pkt_idx   │  pkt_total │  type    │
│  uint32 LE   │  uint16 LE │  uint16 LE │  uint8   │
│  (4 bytes)   │  (2 bytes) │  (2 bytes) │  (1 byte)│
└──────────────┴────────────┴────────────┴──────────┘
  type = 0x01: 视频帧分片
  type = 0x02: 控制事件（pkt_idx=0, pkt_total=1）
```

**视频帧包（type=0x01）：**
```
[8字节包头] + [H.265 NAL Unit 分片数据，最大 1392 字节]
```

**控制事件包（type=0x02）：**
```
[8字节包头] + [ASCII 事件字符串，无需分片]
```

**控制事件字符串格式：**
```
M:5.2,-3.1           鼠标移动（dx/dy 相对位移，单位 dp）
MC:L                  鼠标左键点击
MC:R                  鼠标右键点击
MD:L                  鼠标左键按下
MU:L                  鼠标左键释放
MW:3                  鼠标滚轮（正=上，负=下）
K:36                  键盘单键（CGKeyCode）
KC:cmd,9              键盘组合键 (⌘V)
T:hello world         文字注入
```

---

## 六、关键性能指标（MVP 验收标准）

| 指标 | 目标值 |
|------|-------|
| 局域网端到端延迟 | < 100ms（包含捕获+编码+传输+解码+渲染） |
| 设备发现时间 | < 3 秒 |
| 帧率切换响应 | < 500ms |
| UDP 包大小 | ≤ 1400 字节（避免 IP 分片） |
| 心跳超时判断 | 90 秒 |
| CPU 占用（Mac 推流） | < 15%（硬编保证） |

---

## 七、MVP 边界（不做范围）

以下功能 **明确不在 MVP 范围内**，后续迭代再做：

- ❌ 多显示器支持
- ❌ 外网穿透 / STUN / TURN
- ❌ 加密传输 / 配对码 / 账号验证
- ❌ 文件传输
- ❌ 剪贴板同步
- ❌ H.264 降级兼容
- ❌ 横竖屏自适应复杂布局
- ❌ 录屏/截图
- ❌ 多用户连接

---

## 八、开发优先级（迭代顺序）

### Sprint 1 — 通信骨架
1. Mac：mDNS 注册 + TCP Server（接收 FPS 指令）
2. Android：`NsdManager` mDNS 扫描 + 设备列表 UI + TCP 连接

### Sprint 2 — 视频推流
3. Mac：`CGDisplayStream` 捕获 + `VideoToolbox` H.265 硬编
4. Mac：UDP 视频分片发送
5. Android：`DatagramChannel` UDP 接收 + `FrameAssembler` 帧重组

### Sprint 3 — 视频解码渲染
6. Android：`MediaCodec` 异步硬解码配置（低延迟参数）
7. Android：`SurfaceView` 渲染 + 16:10 黑边适配
8. 端到端视频流联调

### Sprint 4 — 输入控制
9. Android：`TouchpadView` 手势状态机（delta 模式）+ UDP 事件发送
10. Mac：UDP 控制事件接收 + `CGEvent` 注入

### Sprint 5 — 完善体验
11. Android：快捷键区 + 文字输入 + 帧率切换 UI
12. Mac：菜单栏 UI + 权限引导
13. 端到端联调 + 延迟优化 + 120fps 压力测试

---

## 九、风险与注意事项

| 风险 | 说明 | 规避方案 |
|------|------|---------|
| Android `KEY_LOW_LATENCY` 兼容性 | 需要 API 30+（Android 11） | 文档说明最低系统要求，旧版降级不设此参数 |
| 120fps 屏幕捕获 | 部分 Mac 主显示器刷新率不足 120Hz | 捕获前查询 `CGDisplayModeGetRefreshRate`，自动降档 |
| H.265 硬解设备兼容 | 少数旧 Android 设备无 HEVC 硬解 | MVP 阶段不处理，建议 Android 10+ 设备 |
| `CGEventPost` 权限 | 辅助功能权限未开启时注入失败 | 启动时强制检测，未授权则阻止连接并弹窗引导 |
| UDP 乱序到达 | 高帧率下分片可能乱序 | 通过 `pkt_idx` 排序重组，超时 8ms 丢弃不完整帧 |
| Android 主线程阻塞 | UDP 接收/解码必须在独立线程 | UDP 线程设为 `MAX_PRIORITY`，禁止在主线程做任何 IO |
| SurfaceView 与 Compose 混用 | SurfaceView 需用 `AndroidView` 包装 | 已在布局规范中明确，注意 Compose 重组不重建 Surface |

---

*文档由 Kiro AI 生成，供 AI 辅助开发使用。如有迭代，请同步更新本文档。*
