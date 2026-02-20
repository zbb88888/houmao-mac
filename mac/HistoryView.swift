import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var viewModel: HistoryViewModel

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Usage History")
                .font(.title2)
                .bold()

            Text("以下为本机采集的使用情况记录，仅保存在本地。")
                .font(.footnote)
                .foregroundColor(.secondary)

            Divider()

            if viewModel.records.isEmpty {
                Text("暂无历史记录。")
                    .foregroundColor(.secondary)
                    .padding(.top, 16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.records) { record in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(dateFormatter.string(from: record.timestamp))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(record.appName)
                                        .font(.caption)
                                        .bold()
                                }
                                Text(record.text)
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(Color.gray.opacity(0.08))
                            .cornerRadius(6)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            HStack {
                Spacer()
                Button("Clear All History") {
                    viewModel.clearAll()
                }
            }
            .padding(.top, 8)
        }
        .padding()
    }
}

