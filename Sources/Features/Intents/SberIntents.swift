import AppIntents
import Foundation

/// Siri / Shortcuts control of the Sber relay. Runs headless (no Flipper needed)
/// via the Sber cloud, using the token in the Keychain and the device_id saved in
/// the Relay tab.
enum RelayIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noDeviceID
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noDeviceID: return "Set the Sber device_id in the app's Relay tab first."
        }
    }
}

private func performRelay(_ action: String) async throws -> String {
    let dev = (UserDefaults.standard.string(forKey: "sberDeviceID") ?? "")
        .trimmingCharacters(in: .whitespaces)
    guard !dev.isEmpty else { throw RelayIntentError.noDeviceID }
    try await SberCloudClient.shared.apply(action: action, deviceID: dev)
    return action
}

struct ToggleSberRelayIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Sber relay"
    static var description = IntentDescription("Toggle the Sber relay via the Sber cloud.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await performRelay("toggle")
        return .result(dialog: "Toggled the Sber relay.")
    }
}

struct TurnOnSberRelayIntent: AppIntent {
    static var title: LocalizedStringResource = "Turn on Sber relay"
    static var description = IntentDescription("Turn the Sber relay on via the Sber cloud.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await performRelay("on")
        return .result(dialog: "Sber relay on.")
    }
}

struct TurnOffSberRelayIntent: AppIntent {
    static var title: LocalizedStringResource = "Turn off Sber relay"
    static var description = IntentDescription("Turn the Sber relay off via the Sber cloud.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await performRelay("off")
        return .result(dialog: "Sber relay off.")
    }
}

struct UnleashedAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleSberRelayIntent(),
                    phrases: ["Toggle the relay in \(.applicationName)",
                              "Toggle \(.applicationName) relay"],
                    shortTitle: "Toggle relay", systemImageName: "power")
        AppShortcut(intent: TurnOnSberRelayIntent(),
                    phrases: ["Turn on the relay in \(.applicationName)",
                              "\(.applicationName) relay on"],
                    shortTitle: "Relay on", systemImageName: "power")
        AppShortcut(intent: TurnOffSberRelayIntent(),
                    phrases: ["Turn off the relay in \(.applicationName)",
                              "\(.applicationName) relay off"],
                    shortTitle: "Relay off", systemImageName: "power")
    }
}
