import SwiftUI
import Combine

/// App settings stored in UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var showTimestamp: Bool {
        didSet {
            UserDefaults.standard.set(showTimestamp, forKey: "showTimestamp")
        }
    }

    @Published var showAppSwitch: Bool {
        didSet {
            UserDefaults.standard.set(showAppSwitch, forKey: "showAppSwitch")
        }
    }

    private init() {
        self.showTimestamp = UserDefaults.standard.bool(forKey: "showTimestamp")
        self.showAppSwitch = UserDefaults.standard.bool(forKey: "showAppSwitch")
    }
}
