import SwiftUI

struct SettingsView: View {
    @AppStorage("showTimestamp") private var showTimestamp = false
    @AppStorage("showAppSwitch") private var showAppSwitch = false
    @ObservedObject private var settings = AppSettings.shared

    @State private var isAddingWorker = false
    @State private var editingWorkerID: UUID?
    @State private var workerName = ""
    @State private var workerURL = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Show timestamp", isOn: $showTimestamp)
            Toggle("Show app switch", isOn: $showAppSwitch)

            Divider()

            Text("Workers")
                .font(.headline)

            ForEach(settings.workers) { worker in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(worker.name)
                            .font(.system(size: 13, weight: .medium))
                        Text(worker.url)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Edit") {
                        workerName = worker.name
                        workerURL = worker.url
                        editingWorkerID = worker.id
                    }
                    .buttonStyle(.borderless)
                    Button(role: .destructive) {
                        settings.removeWorker(id: worker.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 2)
            }

            if isAddingWorker || editingWorkerID != nil {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Name", text: $workerName)
                        .textFieldStyle(.roundedBorder)
                    TextField("URL (e.g. http://localhost:8081)", text: $workerURL)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Save") {
                            let name = workerName.trimmingCharacters(in: .whitespaces)
                            let url = workerURL.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty, !url.isEmpty else { return }
                            if let id = editingWorkerID {
                                settings.updateWorker(id: id, name: name, url: url)
                            } else {
                                settings.addWorker(name: name, url: url)
                            }
                            resetForm()
                        }
                        Button("Cancel") {
                            resetForm()
                        }
                    }
                }
                .padding(.top, 4)
            } else {
                Button(action: { isAddingWorker = true }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }
        }
        .toggleStyle(.checkbox)
        .padding(20)
        .frame(width: 340, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle("")
    }

    private func resetForm() {
        workerName = ""
        workerURL = ""
        isAddingWorker = false
        editingWorkerID = nil
    }
}
