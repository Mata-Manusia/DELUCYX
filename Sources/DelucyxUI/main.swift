import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // no Dock icon — menubar only
let delegate = AppDelegate()
app.delegate = delegate
app.run()
