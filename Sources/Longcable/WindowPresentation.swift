// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import AppKit
import SwiftUI

// Keep the menu-bar utility alive after closing its window, but always reopen
// that same main window when Finder/Dock asks to open the app again.
@MainActor final class WindowPresentation {
    static let shared = WindowPresentation()
    private weak var window: NSWindow?
    var createWindow: (() -> Void)?
    private var waitingToShow = false
    func show() {
        guard let window else {
            waitingToShow = true
            createWindow?()
            return
        }
        present(window)
    }
    func attach(_ window: NSWindow) {
        self.window = window
        window.isReleasedWhenClosed = false
        if waitingToShow {
            waitingToShow = false
            // Avoid ordering a hosting window while SwiftUI is laying it out.
            DispatchQueue.main.async { [weak self, weak window] in
                if let window { self?.present(window) }
            }
        }
    }
    private func present(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
struct WindowRegistration: NSViewRepresentable {
    final class Attachment: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { WindowPresentation.shared.attach(window) }
        }
    }
    func makeNSView(context: Context) -> Attachment { Attachment() }
    func updateNSView(_ view: Attachment, context: Context) {}
}
struct MainApplicationView: View {
    @ObservedObject var model: SharingModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        SharingView(model: model)
            .background(WindowRegistration())
            .onAppear { WindowPresentation.shared.createWindow = { openWindow(id: "devices") } }
    }
}
