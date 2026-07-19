import SwiftUI

/// Lightweight design-system seed for a modern, premium look: card containers,
/// status pills, and section headers built on native materials. Shared across the
/// app so the redesign stays consistent (Relay first, then dashboard / other tabs).
enum Theme {
    static let accent = Color.orange
    static let cardRadius: CGFloat = 18
    static let cardSpacing: CGFloat = 14
}

/// A premium card surface: material fill, hairline stroke, soft shadow.
struct CardBackground: ViewModifier {
    var tint: Color? = nil
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder((tint ?? Color.primary).opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
    }
}

extension View {
    func card(tint: Color? = nil, padding: CGFloat = 16) -> some View {
        modifier(CardBackground(tint: tint, padding: padding))
    }
}

/// A titled card: small uppercase header + optional icon, content below.
struct SectionCard<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    var accessory: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.caption).foregroundStyle(Theme.accent) }
                Text(title.uppercased())
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Spacer()
                if let accessory { accessory }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// Compact status chip: colored dot/icon + label on a tinted capsule.
struct StatusPill: View {
    let text: String
    var color: Color = .secondary
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.caption2)
            } else {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text(text).font(.caption).fontWeight(.medium)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// A pill-style action button used for quick controls (On / Off / Toggle).
struct PillButton: View {
    let title: String
    var systemImage: String? = nil
    var role: ButtonRole? = nil
    var tint: Color = Theme.accent
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
        }
        .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .foregroundStyle(tint)
    }
}

/// Scrollable container with consistent card spacing and grouped background.
struct CardScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(spacing: Theme.cardSpacing) { content }
                .padding(16)
        }
        .background(Color(.systemGroupedBackground))
    }
}
