import SwiftUI

struct SettingsView: View {
    @AppStorage("showTimestamp") private var showTimestamp = false
    @AppStorage("showAppSwitch") private var showAppSwitch = false
    @ObservedObject private var settings = AppSettings.shared

    @State private var editingWorkerID: UUID?
    @State private var workerName = ""
    @State private var workerURL = ""
    @State private var workerError = ""

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
                        workerError = ""
                    }
                    .buttonStyle(.borderless)
                    Button(role: .destructive) {
                        settings.workers.removeAll { $0.id == worker.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 2)
            }

            if editingWorkerID != nil {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Name (no spaces)", text: $workerName)
                        .textFieldStyle(.roundedBorder)
                    TextField("URL (e.g. http://localhost:8081)", text: $workerURL)
                        .textFieldStyle(.roundedBorder)
                    if !workerError.isEmpty {
                        Text(workerError)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }
                    HStack {
                        Button("Save") { saveWorker() }
                        Button("Cancel") { resetForm() }
                    }
                }
                .padding(.top, 4)
            } else {
                Button(action: { editingWorkerID = UUID() }) {
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

    private func saveWorker() {
        let name = workerName.trimmingCharacters(in: .whitespaces)
        let url = workerURL.trimmingCharacters(in: .whitespaces)

        // Validate
        if name.isEmpty || url.isEmpty {
            workerError = "Name and URL are required."
            return
        }
        if name.contains(where: \.isWhitespace) {
            workerError = "Name cannot contain spaces."
            return
        }
        if URL(string: url) == nil {
            workerError = "Invalid URL."
            return
        }
        // Duplicate check (skip self when editing)
        let duplicate = settings.workers.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.id != editingWorkerID
        }
        if duplicate != nil {
            workerError = "A worker named \"\(name)\" already exists."
            return
        }

        if let id = editingWorkerID,
           let i = settings.workers.firstIndex(where: { $0.id == id }) {
            settings.workers[i].name = name
            settings.workers[i].url = url
        } else {
            settings.workers.append(Worker(name: name, url: url))
        }
        resetForm()
    }

    private func resetForm() {
        workerName = ""
        workerURL = ""
        workerError = ""
        editingWorkerID = nil
    }
}
