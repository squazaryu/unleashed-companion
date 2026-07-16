import SwiftUI
import UIKit

struct ShareImage: Identifiable { let id = UUID(); let url: URL }

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ScreenView: View {
    @EnvironmentObject var ble: FlipperBLE
    @EnvironmentObject var control: FlipperControl
    @State private var shareItem: ShareImage?

    // Quick-launch for the Flipper's built-in apps (moved here from Files — this
    // is the screen-mirror tab, so launching an app and watching it makes sense).
    static let builtInApps: [(String, String)] = [
        ("Sub-GHz", "dot.radiowaves.right"),
        ("NFC", "wave.3.right"),
        ("125 kHz RFID", "key"),
        ("Infrared", "av.remote"),
        ("Bad USB", "cable.connector"),
        ("GPIO", "cpu")
    ]

    var body: some View {
        NavigationStack {
            Group {
                if ble.state != .ready {
                    ContentUnavailableView("Not connected", systemImage: "rectangle.on.rectangle.slash",
                        description: Text("Connect to a Flipper on the Device tab."))
                } else {
                    VStack(spacing: 24) {
                        screen
                        controls.card()
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(Color(.systemGroupedBackground))
                }
            }
            .navigationTitle("Remote")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(ScreenView.builtInApps, id: \.0) { item in
                            Button { Task { try? await control.startApp(item.0) } } label: {
                                Label(item.0, systemImage: item.1)
                            }
                        }
                    } label: { Image(systemName: "square.grid.2x2") }
                    .disabled(ble.state != .ready)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { captureScreenshot() } label: { Image(systemName: "camera") }
                        .disabled(ble.state != .ready)
                }
            }
            .sheet(item: $shareItem) { ActivityView(items: [$0.url]) }
            .onAppear { if ble.state == .ready { control.startScreenStream() } }
            .onDisappear { control.stopScreenStream() }
        }
    }

    /// Render the current mirror buffer to a PNG (orange bg, black pixels, 8×) and
    /// hand it to the share sheet.
    private func captureScreenshot() {
        let w = FlipperControl.screenW, h = FlipperControl.screenH
        let px = control.screenPixels
        guard px.count >= w * h else { return }
        let scale = 8
        let size = CGSize(width: w * scale, height: h * scale)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(red: 0.96, green: 0.55, blue: 0.06, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            for y in 0..<h {
                for x in 0..<w where px[y * w + x] {
                    ctx.cgContext.fill(CGRect(x: x * scale, y: y * scale, width: scale, height: scale))
                }
            }
        }
        guard let data = img.pngData() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flipper-screen.png")
        try? data.write(to: url)
        shareItem = ShareImage(url: url)
    }

    private var screen: some View {
        Canvas { ctx, size in
            let w = FlipperControl.screenW, h = FlipperControl.screenH
            let px = size.width / CGFloat(w)
            let py = size.height / CGFloat(h)
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.96, green: 0.55, blue: 0.06)))
            for y in 0..<h {
                for x in 0..<w where control.screenPixels[y * w + x] {
                    let rect = CGRect(x: CGFloat(x) * px, y: CGFloat(y) * py, width: px + 0.5, height: py + 0.5)
                    ctx.fill(Path(rect), with: .color(.black))
                }
            }
        }
        .aspectRatio(CGFloat(FlipperControl.screenW) / CGFloat(FlipperControl.screenH), contentMode: .fit)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.orange.opacity(0.4)))
    }

    private var controls: some View {
        VStack(spacing: 16) {
            dpadButton(.up, "chevron.up")
            HStack(spacing: 16) {
                dpadButton(.left, "chevron.left")
                dpadButton(.ok, "circle.fill")
                dpadButton(.right, "chevron.right")
            }
            dpadButton(.down, "chevron.down")
            Button {
                control.press(.back)
            } label: {
                Label("Back", systemImage: "arrow.uturn.left")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: 320)
    }

    private func dpadButton(_ key: PBGui_InputKey, _ icon: String) -> some View {
        Button {
            control.press(key)
        } label: {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 64, height: 64)
        }
        .buttonStyle(.borderedProminent)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in
            control.press(key, type: .long)
        })
    }
}
