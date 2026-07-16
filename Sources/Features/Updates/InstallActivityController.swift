import Foundation
import ActivityKit
import UnleashedShared

/// Drives the install Live Activity (lock screen + Dynamic Island) while a plugin
/// pack or firmware package set installs. Best-effort: silently no-ops if Live
/// Activities are disabled.
@MainActor
final class InstallActivityController {
    private var activity: Activity<InstallActivityAttributes>?

    func start(total: Int, title: String = "Installing plugins") {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = InstallActivityAttributes.ContentState(current: 0, total: total, name: "Starting…", done: false)
        activity = try? Activity.request(
            attributes: InstallActivityAttributes(title: title),
            content: .init(state: state, staleDate: nil))
    }

    /// End immediately without a "Done" state (used when an install fails).
    func cancel() {
        guard let current = activity else { return }
        Task { await current.end(nil, dismissalPolicy: .immediate) }
        activity = nil
    }

    func update(current: Int, total: Int, name: String) {
        guard let activity else { return }
        let state = InstallActivityAttributes.ContentState(current: current, total: total, name: name, done: false)
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    func finish(installed: Int, total: Int) {
        guard let current = activity else { return }
        let state = InstallActivityAttributes.ContentState(current: installed, total: total, name: "Done", done: true)
        Task {
            await current.end(.init(state: state, staleDate: nil),
                              dismissalPolicy: .after(Date().addingTimeInterval(3)))
        }
        activity = nil
    }
}
