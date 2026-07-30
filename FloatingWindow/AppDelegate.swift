import SwiftUI
import AppKit
import Sparkle

class AppDelegate: NSObject, NSApplicationDelegate {

    var window: NSWindow!
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = updaterController

        let window = NSWindow(
            contentRect: NSRect(x: 400, y: 400, width: 320, height: 220),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = NSColor.clear
        window.level = .floating

        let blur = NSVisualEffectView()
        blur.frame = window.contentView!.bounds
        blur.autoresizingMask = [.width, .height]
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active

        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(
            red: 0.282,
            green: 0.482,
            blue: 0.518,
            alpha: 0.45
        ).cgColor
        tint.frame = blur.bounds
        tint.autoresizingMask = [.width, .height]

        blur.addSubview(tint)

        let hosting = NSHostingView(rootView: ContentView())
        hosting.frame = blur.bounds
        hosting.autoresizingMask = [.width, .height]

        blur.addSubview(hosting)

        window.contentView = blur
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }
}
