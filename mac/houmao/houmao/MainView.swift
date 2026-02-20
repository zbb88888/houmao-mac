import SwiftUI

struct MainView: View {
    @EnvironmentObject var viewModel: MainViewModel
    @EnvironmentObject var historyViewModel: HistoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Ask LLM... 或输入 history 查看使用记录", text: $viewModel.inputText, onCommit: {
                    viewModel.submit(historyHandler: {
                        historyViewModel.load()
                        viewModel.showHistoryWindow()
                    })
                })
                .textFieldStyle(.roundedBorder)

                Button("Send") {
                    viewModel.submit(historyHandler: {
                        historyViewModel.load()
                        viewModel.showHistoryWindow()
                    })
                }
                .keyboardShortcut(.return, modifiers: [.command])
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let user = viewModel.lastUserText, !user.isEmpty {
                        Text("You:")
                            .font(.headline)
                        Text(user)
                            .font(.system(size: 13, design: .monospaced))
                    }

                    if viewModel.isLoading {
                        Text("LLM: Thinking...")
                            .italic()
                            .foregroundColor(.secondary)
                    } else if let reply = viewModel.lastLLMReply, !reply.isEmpty {
                        Text("LLM:")
                            .font(.headline)
                            .padding(.top, 8)
                        Text(reply)
                            .font(.system(size: 13, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 360)
        .sheet(isPresented: $viewModel.isHistoryPresented) {
            HistoryView()
                .environmentObject(historyViewModel)
        }
    }
}

