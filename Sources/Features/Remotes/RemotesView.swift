import SwiftUI

/// Persisted list of favorite Sub-GHz files for one-tap transmit.
enum SubGhzFavorites {
    private static let key = "subghzFavorites"
    static func all() -> [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func contains(_ p: String) -> Bool { all().contains(p) }
    static func toggle(_ p: String) {
        var a = all()
        if let i = a.firstIndex(of: p) { a.remove(at: i) } else { a.append(p) }
        UserDefaults.standard.set(a, forKey: key)
    }
    static func remove(_ p: String) {
        UserDefaults.standard.set(all().filter { $0 != p }, forKey: key)
    }
}

/// Big one-tap buttons that transmit favorite saved .sub files via the companion.
struct RemotesView: View {
    @EnvironmentObject var ble: FlipperBLE
    @EnvironmentObject var companion: CompanionBridge
    @State private var favorites = SubGhzFavorites.all()

    var body: some View {
        Group {
            if favorites.isEmpty {
                ContentUnavailableView {
                    Label("No remotes yet", systemImage: "dot.radiowaves.right")
                } description: {
                    Text("In Files, long-press a .sub file → “Add to Remotes”.")
                }
            } else {
                CardScroll {
                    if companion.busy || companion.lastAck != nil {
                        HStack(spacing: 8) {
                            if companion.busy {
                                ProgressView().scaleEffect(0.8); Text("Sending…").font(.caption).foregroundStyle(.secondary)
                            } else if let ack = companion.lastAck {
                                let ok = ack.hasPrefix("ok")
                                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(ok ? .green : .red)
                                Text(ack).font(.system(.caption, design: .monospaced))
                            }
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                    }

                    SectionCard(title: "Remotes", systemImage: "dot.radiowaves.right") {
                        ForEach(Array(favorites.enumerated()), id: \.element) { index, path in
                            HStack(spacing: 12) {
                                Button {
                                    Task { await companion.transmitSubGhz(path) }
                                } label: {
                                    HStack {
                                        Image(systemName: "dot.radiowaves.right").foregroundStyle(.orange)
                                        Text(name(path)).foregroundStyle(.primary)
                                        Spacer()
                                        Image(systemName: "paperplane.fill").foregroundStyle(.orange)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .disabled(ble.state != .ready || companion.busy)
                                Button(role: .destructive) {
                                    SubGhzFavorites.remove(path); favorites = SubGhzFavorites.all()
                                } label: { Image(systemName: "star.slash").foregroundStyle(.secondary) }
                                .buttonStyle(.borderless)
                            }
                            if index < favorites.count - 1 { Divider().opacity(0.4) }
                        }
                        Text("Tap to transmit. Needs the App Bridge companion enabled on the Flipper.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .navigationTitle("Remotes")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { favorites = SubGhzFavorites.all() }
    }

    private func name(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}
