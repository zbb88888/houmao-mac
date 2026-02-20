import SwiftUI
import AppKit

/// Debug view: Test double-click Option key detection
struct HotKeyDebugView: View {
    @State private var lastTriggerTime: Date?
    @State private var triggerCount: Int = 0
    @State private var isMonitoring: Bool = false
    @State private var logs: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Double-Click Option Debug Tool")
                .font(.title2)
                .bold()

            Divider()

            HStack {
                Text("Monitor Status:")
                    .bold()
                Text(isMonitoring ? "✅ Running" : "❌ Stopped")
                    .foregroundColor(isMonitoring ? .green : .red)
            }

            HStack {
                Text("Trigger Count:")
                    .bold()
                Text("\(triggerCount)")
            }

            if let time = lastTriggerTime {
                HStack {
                    Text("Last Trigger:")
                        .bold()
                    Text(time, style: .time)
                }
            }

            Divider()

            Text("Event Logs:")
                .font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(logs.indices.reversed(), id: \.self) { index in
                        Text(logs[index])
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 200)
            .padding(8)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)

            HStack {
                Button("Clear Logs") {
                    logs.removeAll()
                    triggerCount = 0
                }

                Button("Copy All Logs") {
                    copyLogsToClipboard()
                }

                Spacer()

                Button("Test Window Toggle") {
                    testWindowToggle()
                }
            }

            Text("Instructions: Double-click Option key should increase trigger count")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(width: 500, height: 450)
        .onAppear {
            setupMonitoring()
        }
    }

    private func setupMonitoring() {
        // Check if GlobalHotKeyManager is initialized
        let _ = GlobalHotKeyManager.shared
        isMonitoring = true
        addLog("✅ Monitor started")

        // Add local event listener (can only monitor events within the app)
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let isOption = event.modifierFlags.contains(.option)
            let keyCode = event.keyCode
            self.addLog("🔍 Local event: keyCode=\(keyCode), Option=\(isOption)")
            return event
        }

        // Register notification to receive double-click events
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("HotKeyTriggered"),
            object: nil,
            queue: .main
        ) { _ in
            self.triggerCount += 1
            self.lastTriggerTime = Date()
            self.addLog("🎯 Double-click Option detected!")
        }

        // Check accessibility permission
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
            let accessEnabled = AXIsProcessTrustedWithOptions(options)

            if accessEnabled {
                self.addLog("✅ Accessibility permission: Granted")
            } else {
                self.addLog("⚠️ Accessibility permission: Denied")
                self.addLog("   Please grant access in System Settings > Privacy & Security > Accessibility")
            }
        }
    }

    private func addLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.append("[\(timestamp)] \(message)")

        // Keep only the last 50 logs
        if logs.count > 50 {
            logs.removeFirst()
        }
    }

    private func testWindowToggle() {
        addLog("🧪 Testing window toggle logic")

        if let window = NSApp.keyWindow {
            if window.isVisible {
                window.orderOut(nil)
                addLog("   ✓ Window hidden")
            } else {
                window.makeKeyAndOrderFront(nil)
                addLog("   ✓ Window shown")
            }
        } else {
            addLog("   ⚠️ Window not found")
        }
    }

    private func copyLogsToClipboard() {
        let allLogs = logs.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(allLogs, forType: .string)
        addLog("📋 Logs copied to clipboard (\(logs.count) entries)")
    }
}

#Preview {
    HotKeyDebugView()
}
