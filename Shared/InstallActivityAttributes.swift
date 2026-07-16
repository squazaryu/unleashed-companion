import ActivityKit
import Foundation

/// Shared between the app and the widget extension (same type, same module) so
/// ActivityKit can match the requested Activity to the widget's configuration.
public struct InstallActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var current: Int
        public var total: Int
        public var name: String
        public var done: Bool
        public init(current: Int, total: Int, name: String, done: Bool) {
            self.current = current; self.total = total; self.name = name; self.done = done
        }
    }
    public var title: String
    public init(title: String) { self.title = title }
}
