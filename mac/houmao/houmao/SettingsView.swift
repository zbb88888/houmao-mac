import SwiftUI

struct SettingsView: View {
    @AppStorage("showTimestamp") private var showTimestamp = false
    @AppStorage("showAppSwitch") private var showAppSwitch = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Show timestamp", isOn: $showTimestamp)
            Toggle("Show app switch", isOn: $showAppSwitch)
        }
        .toggleStyle(.checkbox)
        .padding(20)
        .frame(width: 240, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle("")
    }
}
