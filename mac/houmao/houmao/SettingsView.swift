import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Toggle("show timestamp", isOn: $settings.showTimestamp)
                .font(.system(size: 13))

            Toggle("show app switch", isOn: $settings.showAppSwitch)
                .font(.system(size: 13))

            Spacer()

            HStack {
                Spacer()

                Button("OK") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 300, height: 120)
    }
}
