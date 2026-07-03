import SwiftUI

// MARK: - Theme
//
// A named color scheme. Views read colors by role (background / surface / text
// …) from `AppTheme.current`, never hardcoded values, so switching themes later
// is a one-line change (add a factory like `Theme.dark()` and set it).

struct Theme {
    let background: Color      // window background
    let surface: Color         // cards / assistant bubbles / code blocks
    let textPrimary: Color
    let textSecondary: Color
    let divider: Color
    let accent: Color          // user bubble, buttons, highlights
    let onAccent: Color        // text / icons drawn on `accent`
    let warning: Color
}

extension Theme {
    /// 绿豆沙 — the classic low-contrast, eye-care green.
    static func mungBean() -> Theme {
        Theme(
            background: Color(hex: 0xC7EDCC),
            surface: Color(hex: 0xB6DFBC),
            textPrimary: Color(hex: 0x2F3A30),
            textSecondary: Color(hex: 0x5F6E62),
            divider: Color(hex: 0xA8D4AE),
            accent: Color(hex: 0x3E8E5A),
            onAccent: .white,
            warning: Color(hex: 0xC98A5E)
        )
    }
}

/// The active theme, applied app-wide. Swap this to switch themes later.
enum AppTheme {
    static var current: Theme = .mungBean()
}

extension Color {
    /// Create a color from a 24-bit RGB hex literal, e.g. `Color(hex: 0xC7EDCC)`.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
