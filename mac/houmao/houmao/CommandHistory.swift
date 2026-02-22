import Foundation

/// Command history manager for input field navigation.
final class CommandHistory {
    private let maxCount = 100
    private var history: [String] = []
    private var currentIndex: Int = -1

    /// Add a new command to history.
    func add(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Remove duplicates
        history.removeAll { $0 == trimmed }

        // Add to end
        history.append(trimmed)

        // Limit size
        if history.count > maxCount {
            history.removeFirst(history.count - maxCount)
        }

        // Reset index
        currentIndex = -1
    }

    /// Navigate to previous command (up arrow).
    func previous() -> String? {
        guard !history.isEmpty else { return nil }

        if currentIndex == -1 {
            currentIndex = history.count - 1
        } else if currentIndex > 0 {
            currentIndex -= 1
        }

        return history[currentIndex]
    }

    /// Navigate to next command (down arrow).
    func next() -> String? {
        guard !history.isEmpty, currentIndex >= 0 else { return nil }

        if currentIndex < history.count - 1 {
            currentIndex += 1
            return history[currentIndex]
        } else {
            // Reached end, return empty
            currentIndex = -1
            return ""
        }
    }

    /// Reset navigation index.
    func resetIndex() {
        currentIndex = -1
    }
}
