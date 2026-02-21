import Foundation
import SwiftUI
import Combine

/// App settings stored in UserDefaults
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var showTimestamp: Bool {
        didSet {
            UserDefaults.standard.set(showTimestamp, forKey: "showTimestamp")
        }
    }

    private init() {
        // Read from UserDefaults, default to false if not set
        if UserDefaults.standard.object(forKey: "showTimestamp") == nil {
            self.showTimestamp = false
        } else {
            self.showTimestamp = UserDefaults.standard.bool(forKey: "showTimestamp")
        }
    }
}
