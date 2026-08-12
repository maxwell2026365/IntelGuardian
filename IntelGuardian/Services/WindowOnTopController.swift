#if os(macOS)
import AppKit
import Combine

/// Applies the "always on top" preference to the app's main window by raising
/// its `window.level` to `.floating`. macOS only — iOS has no floating-window
/// concept, so this type is not compiled there.
@MainActor
final class WindowOnTopController: ObservableObject {
    private var cancellable: AnyCancellable?

    /// Observes `settings.windowOnTop` and applies it to the key/main window
    /// whenever it changes. Call once at app startup.
    func observe(_ settings: AppSettings) {
        apply(settings.windowOnTop)
        cancellable = settings.$windowOnTop
            .dropFirst()
            .sink { [weak self] onTop in
                self?.apply(onTop)
            }
    }

    private func apply(_ onTop: Bool) {
        let level: NSWindow.Level = onTop ? .floating : .normal
        for window in NSApp.windows {
            if window.isMainWindow || window.isKeyWindow || window.title.contains("IntelGuardian") {
                window.level = level
            }
        }
    }
}
#endif
