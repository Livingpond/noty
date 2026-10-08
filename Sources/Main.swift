import AppKit

@main
enum NotyMain {
    /// NSApplication.delegate is unowned — hold the delegate here for the process lifetime.
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
