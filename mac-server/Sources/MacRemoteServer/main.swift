import AppKit

// Menu-bar app entry. We use NSApplication manually because SPM executables
// don't get the @main / Info.plist treatment automatically.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon, no main window
app.run()
