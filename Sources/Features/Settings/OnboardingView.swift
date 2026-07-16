import SwiftUI

private struct OnboardStep: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let body: String
}

/// First-run guide. Paged steps covering pairing, App Bridge, Sber, AI Radar.
struct OnboardingView: View {
    var onDone: () -> Void
    @State private var page = 0

    private let steps: [OnboardStep] = [
        .init(icon: "dot.radiowaves.left.and.right",
              title: "Connect your Flipper",
              body: "Open the Device tab and tap your Flipper to pair over Bluetooth. The status dot turns green when it's ready."),
        .init(icon: "antenna.radiowaves.left.and.right",
              title: "Enable App Bridge",
              body: "On the Flipper: Settings → Bluetooth → App Bridge. This powers the Sber relay, AI Radar push and ARF offload."),
        .init(icon: "power",
              title: "Sber relay (optional)",
              body: "In the Relay tab, tap “Log in with Sber” and set your device_id. Then toggle it by voice: “Hey Siri, toggle the relay.”"),
        .init(icon: "chart.bar.xaxis",
              title: "AI Radar",
              body: "Run the AI Radar Bridge app on your Mac. The phone finds it automatically on your network — leave the bridge URL empty."),
        .init(icon: "externaldrive.badge.timemachine",
              title: "Backup & Remotes",
              body: "Back up your SD card to the phone (Device → Backup), edit text files in Files, and fire favorite .sub remotes from Device → Remotes.")
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { idx, step in
                    VStack(spacing: 24) {
                        Spacer()
                        Image(systemName: step.icon)
                            .font(.system(size: 64)).foregroundStyle(.orange)
                        Text(step.title).font(.title2).bold().multilineTextAlignment(.center)
                        Text(step.body)
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                            .padding(.horizontal, 32)
                        Spacer()
                    }
                    .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            Button {
                if page < steps.count - 1 { withAnimation { page += 1 } } else { onDone() }
            } label: {
                Text(page < steps.count - 1 ? "Next" : "Get started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding()

            Button("Skip") { onDone() }
                .font(.footnote)
                .padding(.bottom, 8)
        }
    }
}
