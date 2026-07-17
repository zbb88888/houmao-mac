import SwiftUI
import Observation

/// A navigation destination shared by the sidebar rail and the command palette,
/// so both offer the exact same set of pages. Each posts `.houmaoEnterXxxWindow`.
struct PanelDestination: Identifiable {
    var id: String { symbol }
    let symbol: String
    let title: String
    /// Extra match terms for the command palette (e.g. english aliases).
    let keywords: [String]
    let notification: Notification.Name

    static let all: [PanelDestination] = [
        .init(symbol: "bubble.left", title: "对话", keywords: ["chat", "对话"], notification: .houmaoEnterChatWindow),
        .init(symbol: "envelope", title: "邮件", keywords: ["mail", "邮件"], notification: .houmaoEnterMailWindow),
        .init(symbol: "arrow.triangle.pull", title: "PR", keywords: ["pr"], notification: .houmaoEnterPRWindow),
        .init(symbol: "smallcircle.filled.circle", title: "Issue", keywords: ["issue"], notification: .houmaoEnterIssueWindow),
        .init(symbol: "checklist", title: "待办", keywords: ["do", "todo", "待办"], notification: .houmaoEnterDoWindow),
        .init(symbol: "scope", title: "目标", keywords: ["goal", "目标"], notification: .houmaoEnterGoalsWindow),
        .init(symbol: "square.and.pencil", title: "编辑器", keywords: ["md", "editor", "编辑器"], notification: .houmaoEnterEditorWindow),
    ]

    func matches(_ term: String) -> Bool {
        let t = term.lowercased()
        return t.isEmpty
            || title.lowercased().contains(t)
            || keywords.contains { $0.contains(t) }
    }
}

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

/// The shared navigation rail on the leading edge of every panel window. A
/// borderless, icon-only strip (VS Code activity-bar style) — intentionally
/// distinct from in-page bordered action buttons (ADR-11 §3). Each destination
/// posts the matching `.houmaoEnterXxxWindow`; the search button (⌘K) opens the
/// command palette owned by `SidebarChrome`.
struct PanelSidebar: View {
    @Environment(SidebarState.self) private var state
    /// Opens the command palette (owned by `SidebarChrome`).
    var onSearch: () -> Void = {}
    private var theme: Theme { AppTheme.current }

    var body: some View {
        VStack(spacing: 4) {
            toggle
            searchButton
            if state.isExpanded {
                Divider().overlay(theme.divider).padding(.horizontal, 8)
                ForEach(PanelDestination.all) { navButton($0) }
            }
            Spacer(minLength: 0)
        }
        // The window's title-bar safe area already offsets content below the
        // traffic lights; this small top pad only aligns the first rail icon
        // with the page header's first button row (MailView.header uses
        // `.padding(.vertical, 10)`).
        .padding(.top, 6)
        .frame(width: state.isExpanded ? 48 : 40)
        .frame(maxHeight: .infinity)
        .background(theme.surface)
    }

    // The rail is a borderless, icon-only navigation strip (VS Code activity-bar
    // style) — intentionally distinct from in-page bordered action buttons
    // (see ADR-11 §3). Uniform square hit-frames keep the icons aligned.
    private var toggle: some View {
        Button {
            state.isExpanded.toggle()
        } label: {
            railIcon("sidebar.left")
        }
        .buttonStyle(.plain)
        .keyboardShortcut("\\", modifiers: .command)
        .help(state.isExpanded ? "收起侧边栏 (⌘\\)" : "展开侧边栏 (⌘\\)")
    }

    private var searchButton: some View {
        Button(action: onSearch) {
            railIcon("magnifyingglass")
        }
        .buttonStyle(.plain)
        .keyboardShortcut("k", modifiers: .command)
        .help("搜索本页 / 命令 (⌘K)")
    }

    private func navButton(_ item: PanelDestination) -> some View {
        Button {
            NotificationCenter.default.post(name: item.notification, object: nil)
        } label: {
            railIcon(item.symbol)
        }
        .buttonStyle(.plain)
        .help(item.title)
    }

    private func railIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17))
            .foregroundStyle(theme.textSecondary)
            .frame(width: 40, height: 32)
            .contentShape(Rectangle())
    }
}

/// Wraps a panel window's content with the shared navigation rail on the leading
/// edge plus the command-palette overlay (pinned near the top so it doesn't
/// cover the body). `pageName`/`paletteSearch` give the palette this window's
/// context — `paletteSearch`, when provided, live-filters the page's content.
struct SidebarChrome<Content: View>: View {
    var pageName: String = "本页"
    var paletteSearch: (@MainActor (String) -> Void)? = nil
    var helpLines: [String] = []
    @ViewBuilder var content: Content

    @State private var showPalette = false
    private var theme: Theme { AppTheme.current }

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                PanelSidebar(onSearch: { showPalette = true })
                Divider().overlay(theme.divider)
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if showPalette {
                // Near-invisible tap-catcher: dismiss on outside click without
                // dimming or covering the body.
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { showPalette = false }
                CommandPaletteView(
                    context: PaletteContext(pageName: pageName, onSearch: paletteSearch, helpLines: helpLines),
                    onClose: { showPalette = false }
                )
                .padding(.top, 64)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .environment(SidebarState.shared)
        .animation(.easeOut(duration: 0.12), value: showPalette)
    }
}
