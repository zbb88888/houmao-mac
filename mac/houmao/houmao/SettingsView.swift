import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Toggle("show timestamp", isOn: $settings.showTimestamp)
                .font(.system(size: 13))

            Spacer()

            HStack {
                Spacer()
                Button("OK") {
                    NSApplication.shared.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 300, height: 120)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
