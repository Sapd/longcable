// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import AppKit

@MainActor enum AppArtwork {
    static let menuBar: NSImage = {
        let image = Bundle.main.url(forResource: "LongcableMenuBarIconTemplate", withExtension: "pdf")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "cable.connector.horizontal", accessibilityDescription: "Longcable Server")!
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()
    static var appIcon: NSImage {
        Bundle.main.url(forResource: "LongcableAppIcon", withExtension: "icns")
            .flatMap { NSImage(contentsOf: $0) } ?? NSImage(systemSymbolName: "cable.connector.horizontal", accessibilityDescription: "Longcable")!
    }
}
@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppArtwork.appIcon
        let savedDockChoice = UserDefaults.standard.object(forKey: "showInDock") as? Bool
        NSApp.setActivationPolicy((savedDockChoice ?? true) ? .regular : .accessory)
        DispatchQueue.main.async { WindowPresentation.shared.show() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowPresentation.shared.show()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
