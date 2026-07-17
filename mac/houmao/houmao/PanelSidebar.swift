import SwiftUI
import Observation

/// Global collapse state for the shared navigation rail. A singleton so every
/// panel window's `PanelSidebar` reflects the same expanded/collapsed state;
/// persisted so the choice survives relaunches.
@MainActor
@Observable
final class SidebarState {
    static let shared = SidebarState()

    var isExpanded: Bool {
        didSet { UserDefaults.standard.set(isExpanded, forKey: Self.key) }
    }

    private static let key = "houmao.sidebar.expanded"

    private init() {
        isExpanded = (UserDefaults.standard.object(forKey: Self.key) as? Bool) ?? true
    }
}

/// The shared navigation rail shown on the leading edge of every panel window
/// (chat/mail/pr/issue/do/goal/editor). Each button posts the matching
/// `.houmaoEnterXxxWindow` notification so navigation is identical across pages.
/// The top button (or ⌘\) collapses the rail to a thin strip.
struct PanelSidebar: View {
    @Environment(SidebarState.self) private var state
    private var theme: Theme { AppTheme.current }

    private struct NavItem {
        let symbol: String
        let help: String
        let notification: Notification.Name
    }

    private let items: [NavItem] = [
        .init(symbol: "bubble.left", help: "对话", notification: .houmaoEnterChatWindow),
        .init(symbol: "envelope", help: "邮件", notification: .houmaoEnterMailWindow),
        .init(symbol: "arrow.triangle.pull", help: "PR", notification: .houmaoEnterPRWindow),
        .init(symbol: "smallcircle.filled.circle", help: "Issue", notification: .houmaoEnterIssueWindow),
        .init(symbol: "checklist", help: "待办", notification: .houmaoEnterDoWindow),
        .init(symbol: "scope", help: "目标", notification: .houmaoEnterGoalsWindow),
        .init(symbol: "square.and.pencil", help: "编辑器", notification: .houmaoEnterEditorWindow),
    ]

    var body: some View {
        VStack(spacing: 6) {
            toggle
            if state.isExpanded {
                Divider().overlay(theme.divider).padding(.horizontal, 8)
                ForEach(items, id: \.symbol) { navButton($0) }
            }
            Spacer(minLength: 0)
        }
        // Clear the transparent title bar / traffic lights at the top-left.
        .padding(.top, 34)
        .frame(width: state.isExpanded ? 52 : 40)
        .frame(maxHeight: .infinity)
        .background(theme.surface.opacity(0.4))
    }

    private var toggle: some View {
        Button {
            state.isExpanded.toggle()
        } label: {
            Image(systemName: "sidebar.left")
                .foregroundStyle(theme.textSecondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("\\", modifiers: .command)
        .help(state.isExpanded ? "收起侧边栏 (⌘\\)" : "展开侧边栏 (⌘\\)")
    }

    private func navButton(_ item: NavItem) -> some View {
        Button {
            NotificationCenter.default.post(name: item.notification, object: nil)
        } label: {
            Image(systemName: item.symbol)
                .foregroundStyle(theme.textSecondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.help)
    }
}

/// Wraps a panel window's content with the shared navigation rail on the leading
/// edge. Every panel window's root view is built through this so the rail is
/// consistent and driven by the shared `SidebarState`.
struct SidebarChrome<Content: View>: View {
    @ViewBuilder var content: Content
    private var theme: Theme { AppTheme.current }

    var body: some View {
        HStack(spacing: 0) {
            PanelSidebar()
            Divider().overlay(theme.divider)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(SidebarState.shared)
    }
}
