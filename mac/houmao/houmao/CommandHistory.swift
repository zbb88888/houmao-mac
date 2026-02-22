import Foundation

final class CommandHistory {
    private let maxCount = 100
    private var history = [String]()
    private var index = -1

    func add(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        history.removeAll { $0 == trimmed }
        history.append(trimmed)

        if history.count > maxCount {
            history.removeFirst()
        }

        index = -1
    }

    func previous() -> String? {
        guard !history.isEmpty else { return nil }
        index = index == -1 ? history.count - 1 : max(0, index - 1)
        return history[index]
    }

    func next() -> String? {
        guard !history.isEmpty, index >= 0 else { return nil }

        if index < history.count - 1 {
            index += 1
            return history[index]
        }

        index = -1
        return ""
    }

    func reset() {
        index = -1
    }
}
