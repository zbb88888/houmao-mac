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

    @Published var showAppSwitch: Bool {
        didSet {
            UserDefaults.standard.set(showAppSwitch, forKey: "showAppSwitch")
        }
    }

    private init() {
        if UserDefaults.standard.object(forKey: "showTimestamp") == nil {
            self.showTimestamp = false
        } else {
            self.showTimestamp = UserDefaults.standard.bool(forKey: "showTimestamp")
        }

        if UserDefaults.standard.object(forKey: "showAppSwitch") == nil {
            self.showAppSwitch = false
        } else {
            self.showAppSwitch = UserDefaults.standard.bool(forKey: "showAppSwitch")
        }
    }
}
