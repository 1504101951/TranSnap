import Cocoa

class MainFlutterWindow: NSWindow {
    override func awakeFromNib() {
        super.awakeFromNib()
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        alphaValue = 0
        orderOut(nil)
        StatusBarController.shared.install()
    }
}
