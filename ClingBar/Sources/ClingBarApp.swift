import AppKit

@main
enum ClingBarApp {
    static func main() {
        // Before creating status items / panels: if ClingBar is already running,
        // ping it to re-show and exit this process.
        if !SingleInstance.claimOrHandOff() {
            // Tiny delay so the distributed notification is delivered before exit.
            usleep(80_000)
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
