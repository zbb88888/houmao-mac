import AppKit

/// Listens for double-tap Option key to show/hide main window.
final class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var lastOptionPressTime: TimeInterval = 0
    private var optionKeyState: Bool = false

    private let doubleClickInterval: TimeInterval = 0.4
    private let minPressInterval: TimeInterval = 0.05
    private let leftOptionKeyCode: UInt16 = 58
    private let rightOptionKeyCode: UInt16 = 61

    private init() {
        checkAccessibilityPermission()

        // Monitor both local and global events
        setupLocalMonitor()
        setupGlobalMonitor()
    }

    private func setupLocalMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    private func setupGlobalMonitor() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let isOptionKey = event.keyCode == leftOptionKeyCode || event.keyCode == rightOptionKeyCode
        let isOptionPressed = event.modifierFlags.contains(.option)

        guard isOptionKey else { return }

        // Detect Option key press (transition from released to pressed)
        if isOptionPressed && !optionKeyState {
            let now = Date().timeIntervalSince1970
            let timeSinceLastPress = now - lastOptionPressTime

            if timeSinceLastPress < doubleClickInterval && timeSinceLastPress > minPressInterval {
                toggleMainWindow()
                lastOptionPressTime = 0
            } else {
                lastOptionPressTime = now
            }
            optionKeyState = true
        } else if !isOptionPressed && optionKeyState {
            optionKeyState = false
        }
    }

    private func checkAccessibilityPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func toggleMainWindow() {
        DispatchQueue.main.async {
            guard let mainWindow = NSApp.windows.first(where: { $0.title != "Settings" }) else { return }

            if mainWindow.isVisible {
                mainWindow.orderOut(nil)
            } else {
                mainWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    // Cleanup monitors (for explicit shutdown if needed)
    func cleanup() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
    }
}
