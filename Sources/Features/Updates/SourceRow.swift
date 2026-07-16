import SwiftUI

/// Uniform verdict vocabulary shared by every update source's row, so "Up to date" /
/// "N updates" / "Not installed" render with the identical color+copy regardless of
/// which backend (tumoflip firmware packages vs all-the-plugins community apps)
/// produced the state. Deliberately has NO "needs attention" case — exceptional states
/// (first sync, protected review, failed verify) live in the screen's separate
/// "Needs attention" card instead, so a row's badge always reads as one of these five
/// plain, comparable states and the two rows stay visually symmetric.
enum SourceBadge: Equatable {
    case notChecked
    case checking
    case upToDate
    case updatesAvailable(Int, of: Int? = nil)   // of: total units, e.g. "2 of 4" for groups
    case notInstalled

    var text: String {
        switch self {
        case .notChecked: return "Tap to check"
        case .checking: return "Checking…"
        case .upToDate: return "Up to date"
        case .updatesAvailable(let n, let of):
            if let of { return "\(n) of \(of) need updates" }
            return "\(n) update\(n == 1 ? "" : "s")"
        case .notInstalled: return "Not installed"
        }
    }

    var color: Color {
        switch self {
        case .notChecked, .notInstalled: return .secondary
        case .checking: return .secondary
        case .upToDate: return .green
        case .updatesAvailable: return .orange
        }
    }

    var systemImage: String {
        switch self {
        case .notChecked: return "questionmark.circle"
        case .checking: return "ellipsis.circle"
        case .upToDate: return "checkmark.circle.fill"
        case .updatesAvailable: return "arrow.down.circle.fill"
        case .notInstalled: return "circle.dashed"
        }
    }
}

/// One row in the "Sources" card — identical geometry for every update source
/// regardless of how many groups/files it represents internally, which is the actual
/// mechanism that makes firmware packages and community apps read as two comparable
/// peers in ONE list instead of two differently-shaped features.
struct SourceRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let badge: SourceBadge
    let busy: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.16)).frame(width: 36, height: 36)
                Image(systemName: icon).font(.subheadline).foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).fontWeight(.medium).foregroundStyle(.primary)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if busy {
                ProgressView().scaleEffect(0.8)
            } else {
                Label(badge.text, systemImage: badge.systemImage)
                    .font(.caption).fontWeight(.medium)
                    .foregroundStyle(badge.color)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// A compact tappable row inside the "Needs attention" card — icon + one-line text +
/// chevron, for states that need a deliberate action outside the normal browse-and-
/// install flow (first sync, protected review pending, a failed verify/cleanup).
struct AttentionRow: View {
    let systemImage: String
    let text: String
    var tint: Color = .orange

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tint).frame(width: 20)
            Text(text).font(.subheadline).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
