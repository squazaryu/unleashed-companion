import Foundation

/// One usage window (short/primary or weekly) for an AI provider, mirroring the
/// on-device AI Dashboard app. `used` is 0–100; the device shows both used and
/// `remaining` (100 - used) plus a reset string.
struct AIWindow: Equatable {
    let label: String
    let used: Int
    let reset: String
    var remaining: Int { max(0, 100 - used) }
}

struct AIProvider: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: String
    let source: String
    let short: AIWindow
    let weekly: AIWindow
}

struct AISnapshot: Equatable {
    var updatedAt: String = ""
    var providers: [AIProvider] = []
    var isEmpty: Bool { providers.isEmpty }
}

/// Parser for `/ext/apps_data/ai_dashboard/usage.txt`. Matches the Flipper app's
/// own line parser exactly (ai_dashboard.c): pipe-delimited, a `meta|<time>` line
/// and `provider|id|name|icon|source|short_label|short_used|short_reset|weekly_used|weekly_reset`
/// lines (>= 10 fields).
enum AIRadarParser {
    static func parse(_ text: String) -> AISnapshot {
        var snap = AISnapshot()
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let f = raw.components(separatedBy: "|")
            guard let kind = f.first else { continue }
            if kind == "meta", f.count >= 2 {
                snap.updatedAt = f[1]
            } else if kind == "provider", f.count >= 10 {
                let short = AIWindow(label: f[5].isEmpty ? "5h" : f[5],
                                     used: clamp(f[6]), reset: f[7])
                let weekly = AIWindow(label: "Weekly", used: clamp(f[8]), reset: f[9])
                snap.providers.append(AIProvider(
                    id: f[1],
                    name: f[2].isEmpty ? f[1] : f[2],
                    icon: f[3].isEmpty ? "AI" : f[3],
                    source: f[4], short: short, weekly: weekly))
            }
        }
        return snap
    }

    private static func clamp(_ s: String) -> Int { min(100, max(0, Int(s) ?? 0)) }
}
