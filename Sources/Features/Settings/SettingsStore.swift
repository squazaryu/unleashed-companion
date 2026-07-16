import SwiftUI
import UIKit

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
    /// Window-level override. Applied to the UIWindow before first layout so the
    /// tab bar doesn't re-lay-out (and shift) when a forced scheme arrives late,
    /// which is what SwiftUI's `.preferredColorScheme` causes.
    var uiStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// App-wide user preferences, persisted to UserDefaults.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var appearance: AppearanceMode {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearanceMode") }
    }
    @Published var onboardingDone: Bool {
        didSet { UserDefaults.standard.set(onboardingDone, forKey: "onboardingDone") }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: "appearanceMode") ?? AppearanceMode.dark.rawValue
        appearance = AppearanceMode(rawValue: raw) ?? .dark
        onboardingDone = UserDefaults.standard.bool(forKey: "onboardingDone")
    }
}
