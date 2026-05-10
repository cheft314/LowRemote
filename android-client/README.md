# LowRemote Android Client

Kotlin + Jetpack Compose. Requires Android 11 (API 30)+.

## Opening in Android Studio

1. Open Android Studio → File → Open → select `android-client/`.
2. Android Studio will prompt to generate the Gradle wrapper (`gradlew`, `gradlew.bat`, and the wrapper jar). Accept.
3. Sync Gradle. The first sync will download AGP 8.2.2, Kotlin 1.9.22, and Compose BOM 2024.02.
4. Run the **app** configuration on a physical device on the same Wi-Fi as the Mac.

## Key design decisions

- **Zero-copy video pipeline**: `DatagramSocket` → `FrameAssembler` → `MediaCodec` (async mode) → `SurfaceView`. The Surface is the decoder's direct output — no pixel copies reach the JVM heap.
- **KEY_LOW_LATENCY** on API 30+ disables codec internal reordering buffers.
- **Delta-mode mouse**: touchpad sends `M:dx,dy` (floats). The Mac accumulates onto the current cursor position. Much more trackpad-like than absolute mapping.
- **Shared UDP socket**: `UdpSender` reuses the receiver's socket so Mac sees us as a stable `host:port` endpoint.
- **MulticastLock** is held while the app is in the foreground — many Android Wi-Fi stacks drop mDNS packets otherwise.

## Layout

Fixed horizontal split (forced landscape):

```
┌─────────────────────────────┬───────────────────────┐
│                             │   Shortcuts + Input   │
│                             │      (45% tall)       │
│     Video SurfaceView       ├───────────────────────┤
│      (16:10 in 60% w)       │       Touchpad        │
│                             │      (55% tall)       │
└─────────────────────────────┴───────────────────────┘
```
