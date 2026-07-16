import Foundation
import BackgroundTasks
import UserNotifications

/// Background watcher for new releases across the repos we care about — the
/// all-the-plugins pack AND the ESP32 Marauder firmware. Periodically (≈every 6h,
/// the OS decides) it fetches each repo's latest release tag and posts a LOCAL
/// notification when it changes, so the user hears about updates without opening
/// the app. Local notifications + BGAppRefreshTask need no push/APNs entitlement,
/// so this works fine with a personal developer-cert signed build.
enum PluginUpdateMonitor {
    static let taskID = "com.tumoflip.unleashedcompanion.plugincheck"

    private struct Source {
        let repo: String
        let lastTagKey: String
        let title: String
        let body: (String) -> String
    }

    private static let sources: [Source] = [
        Source(repo: "xMasterX/all-the-plugins",
               lastTagKey: "pluginLastNotifiedTag",
               title: "New Flipper plugin pack",
               body: { "all-the-plugins \($0) is available — open Updates to install the changes." }),
        Source(repo: "justcallmekoko/ESP32Marauder",
               lastTagKey: "esp32LastNotifiedTag",
               title: "New ESP32 Marauder firmware",
               body: { "ESP32Marauder \($0) is out — open Home → ESP32 Firmware to flash it." }),
    ]

    /// Register the BG handler — must run before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            handle(task as! BGAppRefreshTask)
        }
    }

    /// Request notification permission, then schedule the first check. Safe to call
    /// on every foreground: iOS only shows the system prompt when status is
    /// notDetermined; once decided it returns silently (no guard flag needed — an old
    /// guard flag was why the prompt never appeared on upgraded installs).
    static func enableIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            schedule()
        }
    }

    static func schedule() {
        let req = BGAppRefreshTaskRequest(identifier: taskID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 3600)   // ~every 6h, OS decides
        try? BGTaskScheduler.shared.submit(req)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()   // chain the next one
        let work = Task {
            await check()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// Check every source; notify on a changed tag. The first observation per
    /// source is a silent baseline so we don't fire on initial install.
    static func check() async {
        let defaults = UserDefaults.standard
        for s in sources {
            guard let tag = try? await latestTag(s.repo) else { continue }
            let last = defaults.string(forKey: s.lastTagKey)
            if last == nil {
                defaults.set(tag, forKey: s.lastTagKey)          // baseline, no notification
            } else if tag != last {
                defaults.set(tag, forKey: s.lastTagKey)
                notify(source: s, tag: tag)
            }
        }
    }

    private static func latestTag(_ repo: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { throw URLError(.badServerResponse) }
        return tag
    }

    private static func notify(source s: Source, tag: String) {
        let content = UNMutableNotificationContent()
        content.title = s.title
        content.body = s.body(tag)
        content.sound = .default
        let req = UNNotificationRequest(identifier: "\(s.repo)-\(tag)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
