import AppKit
import SwiftUI

/// Calls `action` each time the window hosting this view becomes key. A MenuBarExtra(.window) keeps its content
/// alive, so `onAppear` only runs on the first open; becoming key happens on every open.
struct WindowKeyObserver: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.action = action
    }

    final class ObserverView: NSView {
        var action: (() -> Void)?

        // Selector-based observation: removed automatically when the view is deallocated.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey),
                                                   name: NSWindow.didBecomeKeyNotification, object: window)
            if window.isKeyWindow { action?() }
        }

        @objc private func windowDidBecomeKey(_ notification: Notification) {
            action?()
        }
    }
}
