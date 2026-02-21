import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.system(size: 20, weight: .semibold))
                .padding(.bottom, 8)

            Divider()

            // History section
            VStack(alignment: .leading, spacing: 12) {
                Text("History")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)

                Toggle("Show timestamp in history", isOn: $settings.showTimestamp)
                    .font(.system(size: 13))
            }

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
        .frame(width: 400, height: 250)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
