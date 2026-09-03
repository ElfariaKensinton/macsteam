import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
if #available(macOS 14, *) {
    app.activate()
} else {
    app.activate(ignoringOtherApps: true)
}
app.run()
