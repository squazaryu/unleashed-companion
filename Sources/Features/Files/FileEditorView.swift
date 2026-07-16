import SwiftUI
import CryptoKit

/// Edit a text file on the Flipper. Reads the current bytes fresh over BLE on
/// open (no stale cache), edits in a monospaced editor, and writes the whole file
/// back on Save. Non-UTF-8 (binary) files are detected and refused.
struct FileEditorView: View {
    let file: FlipperFile
    let storage: any DeviceFileStore
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var original = ""
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    @State private var notText = false

    /// Guard against pulling a huge file over BLE into a text editor.
    private static let maxBytes: UInt32 = 512 * 1024

    init(
        file: FlipperFile,
        storage: any DeviceFileStore = FlipperStorage(),
        onSaved: @escaping () -> Void = {}
    ) {
        self.file = file
        self.storage = storage
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if notText {
                    ContentUnavailableView("Not a text file", systemImage: "doc.questionmark",
                        description: Text("This file isn't valid UTF-8 text, so it can't be edited here."))
                } else {
                    TextEditor(text: $text)
                        .font(.system(.callout, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(.horizontal, 4)
                }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(loading || notText || saving || text == original)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 4) {
                    Label("Editing via \(storage.channel.label)", systemImage: storage.channel.systemImage)
                        .font(.caption2)
                        .foregroundStyle(storage.channel == .usb ? .blue : .secondary)
                    if let e = error {
                        Text(e).font(.caption).foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(8)
                .background(.bar)
            }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true; error = nil; defer { loading = false }
        guard file.size <= Self.maxBytes else {
            notText = true
            error = "File is too large to edit here (\(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)))."
            return
        }
        do {
            let data = try await storage.read(file.path)
            if let s = String(data: data, encoding: .utf8) {
                text = s; original = s
            } else {
                notText = true
            }
        } catch {
            self.error = "Couldn't read file: \(error.localizedDescription)"
        }
    }

    private func save() async {
        saving = true; error = nil; defer { saving = false }
        do {
            try await storage.write(file.path, data: Data(text.utf8))
            // Verify it landed (BLE write integrity), like installs do.
            let dev = await storage.md5(file.path)
            let expected = Insecure_md5Hex(Data(text.utf8))
            if dev != nil && dev != expected {
                error = "Saved but verification mismatched — try again."
                return
            }
            original = text
            onSaved()
            dismiss()
        } catch {
            self.error = "Save failed: \(error.localizedDescription)"
        }
    }
}

/// Lowercase hex MD5, matching the Flipper's storage md5sum output.
func Insecure_md5Hex(_ data: Data) -> String {
    Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
