import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class FilesViewModel: ObservableObject {
    @Published var path = "/ext"
    @Published var entries: [FlipperFile] = []
    @Published var loading = false
    @Published var error: String?
    @Published var upload: UploadProgress?
    @Published var cleaning = false
    @Published var cleanResult: String?
    @Published var moving = false
    @Published private(set) var channel: TransferChannel = .ble

    private var currentStorage: any DeviceFileStore = FlipperStorage()
    let control = FlipperControl()

    var storage: any DeviceFileStore { currentStorage }

    func useStorage(_ storage: any DeviceFileStore) {
        currentStorage = storage
        channel = storage.channel
        path = "/ext"
        entries = []
        upload = nil
        error = nil
    }

    /// Create a new folder in the current directory.
    func createFolder(_ name: String) async {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !n.contains("/") else { return }
        let base = path.hasSuffix("/") ? String(path.dropLast()) : path
        do {
            try await storage.makeDirectory("\(base)/\(n)")
            await load()
        } catch {
            self.error = "Couldn't create “\(n)”: \(error.localizedDescription)"
        }
    }

    /// Recursively delete macOS junk (`._*`, `.DS_Store`) and the macOS service
    /// folders a Mac leaves on the SD card, over BLE. Real Flipper files untouched.
    func cleanMacJunk() async {
        cleaning = true; cleanResult = nil; defer { cleaning = false }
        let junkDirs: Set<String> = [
            ".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems", ".DocumentRevisions-V100"
        ]
        var deleted = 0

        func walk(_ p: String, _ depth: Int) async {
            guard depth <= 6 else { return }
            let items = (try? await storage.list(p)) ?? []
            for e in items {
                if !e.isDirectory, e.name.hasPrefix("._") || e.name == ".DS_Store" {
                    if (try? await storage.delete(e.path)) != nil { deleted += 1 }
                } else if e.isDirectory, junkDirs.contains(e.name) {
                    if (try? await storage.delete(e.path, recursive: true)) != nil { deleted += 1 }
                } else if e.isDirectory {
                    await walk(e.path, depth + 1)
                }
            }
        }
        await walk("/ext", 0)
        cleanResult = "Removed \(deleted) macOS junk item\(deleted == 1 ? "" : "s")."
        await load()
    }

    /// Run a file on the Flipper via the companion .fap: Sub-GHz transmit,
    /// NFC/RFID emulate.
    func run(_ file: FlipperFile) async {
        error = nil
        switch (file.name as NSString).pathExtension.lowercased() {
        case "sub":  await CompanionBridge.shared.transmitSubGhz(file.path)
        case "nfc":  await CompanionBridge.shared.emulateNFC(file.path)
        case "rfid": await CompanionBridge.shared.emulateRFID(file.path)
        default:     break
        }
    }

    func open(_ file: FlipperFile) async {
        error = nil
        do {
            switch (file.name as NSString).pathExtension.lowercased() {
            case "sub":  try await control.openSubGhzFile(file.path)
            case "nfc":  try await control.openNFCFile(file.path)
            case "rfid": try await control.openRFIDFile(file.path)
            default:     try await control.startApp(file.path)
            }
        } catch { self.error = error.localizedDescription }
    }

    func load(_ newPath: String? = nil) async {
        if let p = newPath { path = p }
        loading = true; error = nil
        defer { loading = false }
        do { entries = try await storage.list(path) }
        catch {
            // A failure on the USB channel may mean the cable was pulled / USB SD Mode
            // closed mid-session: detect it, fall back to BLE and let the banner explain.
            if channel == .usb, TransferChannelStore.shared.noteUSBFailureIfDisconnected() {
                useStorage(TransferChannelStore.shared.activeStore)
                return
            }
            self.error = error.localizedDescription
        }
    }

    func up() async {
        let root = channel == .usb ? "/ext" : "/"
        guard path != root else { return }
        let parent = (path as NSString).deletingLastPathComponent
        await load(parent.isEmpty ? root : parent)
    }

    func delete(_ file: FlipperFile) async {
        do {
            try await storage.delete(file.path, recursive: file.isDirectory)
            await load()
        } catch { self.error = error.localizedDescription }
    }

    func delete(_ files: [FlipperFile]) async {
        let items = files.sorted {
            $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedDescending
        }
        guard !items.isEmpty else { return }

        moving = true
        defer { moving = false }

        var deleted = 0
        for file in items {
            do {
                try await storage.delete(file.path, recursive: file.isDirectory)
                deleted += 1
            } catch {
                self.error = "Deleted \(deleted)/\(items.count). Failed on “\(file.name)”: \(error.localizedDescription)"
                await load()
                return
            }
        }
        await load()
    }

    /// Move a file/folder into `folder`. Guards against moving a folder into itself
    /// or its own subtree (which the firmware would reject / loop).
    func move(_ file: FlipperFile, to folder: String) async {
        let dest = folder == "/" ? "/\(file.name)" : "\(folder)/\(file.name)"
        if dest == file.path { return }
        if file.isDirectory, (folder + "/").hasPrefix(file.path + "/") {
            error = "Can’t move a folder into itself."; return
        }
        do {
            try await storage.move(file.path, to: dest)
            await load()
        } catch { self.error = error.localizedDescription }
    }

    /// Move several files/folders into one destination folder.
    func move(_ files: [FlipperFile], to folder: String) async {
        let items = files.sorted {
            if $0.isDirectory != $1.isDirectory { return !$0.isDirectory && $1.isDirectory }
            return $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
        guard !items.isEmpty else { return }

        for file in items {
            if file.isDirectory, (folder + "/").hasPrefix(file.path + "/") {
                error = "Can’t move “\(file.name)” into itself."
                return
            }
        }

        moving = true
        defer { moving = false }

        var moved = 0
        for file in items {
            let dest = folder == "/" ? "/\(file.name)" : "\(folder)/\(file.name)"
            guard dest != file.path else { continue }
            do {
                try await storage.move(file.path, to: dest)
                moved += 1
            } catch {
                self.error = "Moved \(moved)/\(items.count). Failed on “\(file.name)”: \(error.localizedDescription)"
                await load()
                return
            }
        }
        await load()
    }

    func uploadFolders(_ urls: [URL]) async {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try await storage.uploadFolder(localURL: url, to: path) { prog in
                    Task { @MainActor in self.upload = prog }
                }
            } catch { self.error = error.localizedDescription }
        }
        upload = nil
        await load()
    }

    func uploadFiles(_ urls: [URL]) async {
        let total = urls.count
        var done = 0
        upload = UploadProgress(filesTotal: total, channel: storage.channel)
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let dest = path == "/" ? "/\(url.lastPathComponent)" : "\(path)/\(url.lastPathComponent)"
                upload?.currentFile = url.lastPathComponent
                upload?.bytesTotal = data.count
                try await storage.write(dest, data: data)
                done += 1
                upload?.filesDone = done
                upload?.bytesDone = data.count
            } catch { self.error = error.localizedDescription }
        }
        upload = nil
        await load()
    }
}

struct FilesView: View {
    @EnvironmentObject var ble: FlipperBLE
    @EnvironmentObject var companion: CompanionBridge
    @EnvironmentObject var transfer: TransferChannelStore
    @StateObject private var vm = FilesViewModel()
    @State private var showFolderImporter = false
    @State private var showFileImporter = false
    @State private var showUSBRootImporter = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var editTarget: FlipperFile?
    @State private var moveTarget: FlipperFile?
    @State private var selecting = false
    @State private var selectedPaths: Set<String> = []
    @State private var bulkMoveTarget: BulkMoveRequest?
    @State private var deleteSelection = false

    private struct BulkMoveRequest: Identifiable {
        let id = UUID()
        let files: [FlipperFile]
    }

    /// Plain-text files that open the editor on a plain TAP. Device-action formats
    /// (sub/nfc/rfid/ir) are intentionally excluded so a tap doesn't hijack them —
    /// they're still editable via the long-press "Edit text" context-menu item.
    static let plainTextExtensions: Set<String> = [
        "txt", "log", "ini", "conf", "cfg", "json", "js", "csv", "md",
        "env", "yml", "yaml", "xml", "html"
    ]
    static func isPlainTextFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.isEmpty || plainTextExtensions.contains(ext)
    }

    var body: some View {
        // Stack-agnostic: rendered inside Home's NavigationStack (Files is no longer a tab).
        Group {
            if !canBrowse {
                unavailableView
            } else {
                fileList
            }
        }
        .navigationTitle("Files")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if canBrowse && !vm.entries.isEmpty {
                        Button(selecting ? "Done" : "Select") {
                            selecting.toggle()
                            if !selecting { selectedPaths.removeAll() }
                        }
                        .disabled(vm.loading || vm.moving)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if selecting {
                        Button {
                            bulkMoveTarget = BulkMoveRequest(files: selectedFiles)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .disabled(selectedPaths.isEmpty || vm.moving)
                        Button(role: .destructive) {
                            deleteSelection = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(selectedPaths.isEmpty || vm.moving)
                    }
                    Menu {
                        Button { showUSBRootImporter = true } label: {
                            Label("Use USB SD folder…", systemImage: "cable.connector")
                        }
                        if transfer.activeChannel == .usb {
                            Button {
                                transfer.useBLE()
                                vm.useStorage(transfer.activeStore)
                                Task { if canBrowse { await vm.load("/ext") } }
                            } label: {
                                Label("Use BLE", systemImage: "bluetooth")
                            }
                        }
                        Divider()
                        Button { newFolderName = ""; showNewFolder = true } label: { Label("New folder…", systemImage: "folder.badge.plus") }
                            .disabled(!canBrowse)
                        Divider()
                        Button { showFolderImporter = true } label: { Label("Upload folder…", systemImage: "square.and.arrow.up.on.square") }
                            .disabled(!canBrowse)
                        Button { showFileImporter = true } label: { Label("Upload files…", systemImage: "doc.badge.plus") }
                            .disabled(!canBrowse)
                        Divider()
                        Button {
                            Task { await vm.cleanMacJunk() }
                        } label: { Label("Clean macOS junk (._*, .DS_Store)", systemImage: "trash.slash") }
                        .disabled(!canBrowse)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .disabled(vm.cleaning || selecting)
                }
            }
            .fileImporter(isPresented: $showUSBRootImporter, allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    activateUSBRoot(url)
                }
            }
            .fileImporter(isPresented: $showFolderImporter, allowedContentTypes: [.folder],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { Task { await vm.uploadFolders(urls) } }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { Task { await vm.uploadFiles(urls) } }
            }
            .sheet(item: $editTarget) { f in
                FileEditorView(file: f, storage: vm.storage) { Task { await vm.load() } }
            }
            .sheet(item: $moveTarget) { f in
                FolderPickerView(storage: vm.storage, title: "Move “\(f.name)”") { dest in
                    Task { await vm.move(f, to: dest) }
                }
            }
            .sheet(item: $bulkMoveTarget) { request in
                FolderPickerView(storage: vm.storage, title: "Move \(request.files.count) item\(request.files.count == 1 ? "" : "s")") { dest in
                    Task {
                        await vm.move(request.files, to: dest)
                        selectedPaths.removeAll()
                        selecting = false
                    }
                }
            }
            .alert("Cleanup", isPresented: Binding(
                get: { vm.cleanResult != nil },
                set: { if !$0 { vm.cleanResult = nil } })) {
                Button("OK", role: .cancel) { vm.cleanResult = nil }
            } message: { Text(vm.cleanResult ?? "") }
            .alert("Delete selected items?", isPresented: $deleteSelection) {
                Button("Delete \(selectedPaths.count)", role: .destructive) {
                    let files = selectedFiles
                    Task {
                        await vm.delete(files)
                        selectedPaths.removeAll()
                        selecting = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deletes selected files and folders from the Flipper SD. This cannot be undone.")
            }
            .alert("New folder", isPresented: $showNewFolder) {
                TextField("Folder name", text: $newFolderName)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Create") { Task { await vm.createFolder(newFolderName) } }
            } message: { Text("Create a folder in \(vm.path)") }
            .alert("Error", isPresented: Binding(
                get: { vm.error != nil },
                set: { if !$0 { vm.error = nil } })) {
                Button("OK", role: .cancel) { vm.error = nil }
            } message: { Text(vm.error ?? "") }
            .task(id: ble.state) { if ble.state == .ready { await vm.load() } }
            .onAppear {
                if transfer.activeChannel == .ble {
                    transfer.restoreSavedUSBRoot(showError: false)
                }
                vm.useStorage(transfer.activeStore)
                if canBrowse, vm.entries.isEmpty {
                    Task { await vm.load("/ext") }
                }
            }
            .onChange(of: transfer.activeChannel) { _ in
                vm.useStorage(transfer.activeStore)
                if canBrowse { Task { await vm.load("/ext") } }
            }
    }

    private var canBrowse: Bool {
        transfer.activeChannel == .usb || ble.state == .ready
    }

    private var selectedFiles: [FlipperFile] {
        vm.entries.filter { selectedPaths.contains($0.path) }
    }

    private var unavailableView: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "Not connected",
                systemImage: "folder.badge.questionmark",
                description: Text("Connect over BLE or select the Flipper SD card via USB.")
            )
            Button {
                activateSavedUSBOrPick()
            } label: {
                Label(transfer.hasSavedUSBRoot ? "Reconnect USB SD" : "Select USB SD", systemImage: "cable.connector")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
    }

    private var fileList: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Button { Task { await vm.load("/ext") } } label: {
                        Image(systemName: "house.fill")
                    }
                    .disabled(vm.path == "/ext")
                    Button { Task { await vm.up() } } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .disabled(vm.path == (vm.channel == .usb ? "/ext" : "/"))
                    Divider().frame(height: 18)
                    Image(systemName: "externaldrive").foregroundStyle(.secondary)
                    Text(vm.path).font(.system(.footnote, design: .monospaced))
                        .lineLimit(1).truncationMode(.head)
                    Spacer()
                    StatusPill(
                        text: vm.channel.label,
                        color: vm.channel == .usb ? .blue : .secondary,
                        systemImage: vm.channel.systemImage
                    )
                }
                .buttonStyle(.borderless)
                .tint(Theme.accent)
            }
            if transfer.usbInterrupted {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("USB SD disconnected").font(.subheadline).fontWeight(.medium)
                            Text("Switched to BLE. Reconnect the cable and open USB SD Mode on the Flipper, then tap Reconnect.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                if transfer.reconnectUSB() {
                                    vm.useStorage(transfer.activeStore)
                                    Task { await vm.load() }
                                }
                            } label: { Label("Reconnect USB SD", systemImage: "arrow.clockwise") }
                            .buttonStyle(.bordered).tint(Theme.accent)
                        }
                    }
                }
            }
            if vm.channel == .ble {
                Section {
                    HStack(spacing: 12) {
                        Label("Files BLE", systemImage: "bluetooth")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            activateSavedUSBOrPick()
                        } label: {
                            Label("USB SD", systemImage: "cable.connector")
                        }
                        .buttonStyle(.bordered)
                    }
                } footer: {
                    Text("Cable file access needs the SD card folder selected in Files once.")
                }
            }
            if companion.busy || companion.lastAck != nil {
                Section {
                    HStack {
                        if companion.busy {
                            ProgressView().scaleEffect(0.8)
                            Text("Companion working…").font(.caption)
                        } else if let ack = companion.lastAck {
                            let ok = ack.hasPrefix("ok")
                            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(ok ? .green : .red)
                            Text(ack).font(.system(.caption, design: .monospaced))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if let up = vm.upload {
                Section { uploadRow(up) }
            }
            if vm.cleaning {
                Section {
                    HStack { ProgressView().scaleEffect(0.8); Text("Cleaning macOS junk…").font(.caption) }
                }
            }
            if vm.moving {
                Section {
                    HStack { ProgressView().scaleEffect(0.8); Text("Updating files…").font(.caption) }
                }
            }
            if selecting {
                Section {
                    HStack(spacing: 12) {
                        Text("\(selectedPaths.count) selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("All") {
                            selectedPaths = Set(vm.entries.map(\.path))
                        }
                        .disabled(vm.entries.isEmpty)
                        Button("Clear") {
                            selectedPaths.removeAll()
                        }
                        .disabled(selectedPaths.isEmpty)
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let err = vm.error {
                Section { Text(err).foregroundStyle(.red).font(.caption) }
            }
            Section {
                if vm.loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if vm.entries.isEmpty {
                    Text("Empty folder").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(vm.entries) { f in
                    row(f)
                }
            } header: {
                if !vm.entries.isEmpty {
                    let dirs = vm.entries.filter(\.isDirectory).count
                    Text("\(dirs) folder\(dirs == 1 ? "" : "s") · \(vm.entries.count - dirs) file\(vm.entries.count - dirs == 1 ? "" : "s")")
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await vm.load() }
    }

    private func row(_ f: FlipperFile) -> some View {
        HStack {
            if selecting {
                Image(systemName: selectedPaths.contains(f.path) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedPaths.contains(f.path) ? Theme.accent : .secondary)
            }
            Image(systemName: f.isDirectory ? "folder.fill" : icon(for: f.name))
                .foregroundStyle(f.isDirectory ? .orange : .secondary)
            Text(f.name)
            Spacer()
            if !f.isDirectory {
                Text(byteString(f.size)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if selecting {
                toggleSelection(f)
            } else if f.isDirectory {
                Task { await vm.load(f.path) }
            } else if (f.name as NSString).pathExtension.lowercased() == "fap", vm.channel == .ble {
                Task { try? await vm.control.startApp(f.path) }
            } else if FilesView.isPlainTextFile(f.name) {
                editTarget = f
            }
        }
        // Edit lives in the context menu (long-press) so it doesn't crowd the
        // sub/nfc/rfid swipe actions.
        .contextMenu {
            if selecting {
                Button { toggleSelection(f) } label: {
                    Label(selectedPaths.contains(f.path) ? "Deselect" : "Select",
                          systemImage: selectedPaths.contains(f.path) ? "checkmark.circle.fill" : "circle")
                }
            } else {
                Button { moveTarget = f } label: { Label("Move to…", systemImage: "folder") }
            }
            if !f.isDirectory, (f.name as NSString).pathExtension.lowercased() != "fap" {
                Button { editTarget = f } label: { Label("Edit text", systemImage: "pencil") }
            }
            if vm.channel == .ble, !f.isDirectory, (f.name as NSString).pathExtension.lowercased() == "sub" {
                let fav = SubGhzFavorites.contains(f.path)
                Button { SubGhzFavorites.toggle(f.path) } label: {
                    Label(fav ? "Remove from Remotes" : "Add to Remotes",
                          systemImage: fav ? "star.slash" : "star")
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if !selecting {
                Button(role: .destructive) { Task { await vm.delete(f) } } label: { Label("Delete", systemImage: "trash") }
            }
        }
        .swipeActions(edge: .leading) {
            if vm.channel == .ble, !selecting, !f.isDirectory {
                let ext = (f.name as NSString).pathExtension.lowercased()
                switch ext {
                case "sub":
                    Button { Task { await vm.run(f) } } label: { Label("Send", systemImage: "dot.radiowaves.right") }
                        .tint(.orange)
                case "nfc", "rfid":
                    Button { Task { await vm.run(f) } } label: { Label("Emulate", systemImage: "wave.3.right.circle") }
                        .tint(.purple)
                default: EmptyView()
                }
                if ["sub", "nfc", "rfid"].contains(ext) {
                    Button { Task { await vm.open(f) } } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                        .tint(.blue)
                }
            }
        }
    }

    private func activateUSBRoot(_ url: URL) {
        transfer.useUSBRoot(url)
        vm.useStorage(transfer.activeStore)
        if let err = transfer.lastUSBError {
            vm.error = err
        } else {
            Task { await vm.load("/ext") }
        }
    }

    private func activateSavedUSBOrPick() {
        if transfer.restoreSavedUSBRoot(showError: false) {
            vm.useStorage(transfer.activeStore)
            Task { await vm.load("/ext") }
        } else {
            showUSBRootImporter = true
        }
    }

    private func toggleSelection(_ file: FlipperFile) {
        if selectedPaths.contains(file.path) {
            selectedPaths.remove(file.path)
        } else {
            selectedPaths.insert(file.path)
        }
    }

    private func uploadRow(_ up: UploadProgress) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                ProgressView().scaleEffect(0.8)
                Text("Uploading via \(up.channel.label) \(up.filesDone)/\(up.filesTotal)").font(.caption)
            }
            Text(up.currentFile).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            if up.bytesTotal > 0 {
                ProgressView(value: Double(up.bytesDone), total: Double(up.bytesTotal))
            }
        }
    }

    private func icon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "sub": return "dot.radiowaves.right"
        case "nfc": return "wave.3.right"
        case "rfid", "ibtn": return "key"
        case "ir": return "av.remote"
        case "fap": return "app.badge"
        case "txt", "log": return "doc.text"
        default: return "doc"
        }
    }

    private func byteString(_ n: UInt32) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}

/// Destination-folder browser for "Move to…". Lists subfolders, lets you navigate
/// in/up, and confirm the current folder as the move destination.
struct FolderPickerView: View {
    let storage: any DeviceFileStore
    let title: String
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path = "/ext"
    @State private var dirs: [FlipperFile] = []
    @State private var loading = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "externaldrive")
                        Text(path).font(.system(.footnote, design: .monospaced)).lineLimit(1)
                        Spacer()
                        if path != (storage.channel == .usb ? "/ext" : "/") {
                            Button { Task { await up() } } label: { Image(systemName: "arrow.up.left") }
                        }
                        StatusPill(
                            text: storage.channel.label,
                            color: storage.channel == .usb ? .blue : .secondary,
                            systemImage: storage.channel.systemImage
                        )
                    }
                }
                Section("Folders") {
                    if loading { ProgressView() }
                    ForEach(dirs) { d in
                        Button { Task { await load(d.path) } } label: {
                            HStack {
                                Image(systemName: "folder.fill").foregroundStyle(.orange)
                                Text(d.name)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if dirs.isEmpty && !loading {
                        Text("No subfolders here").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Move here") { onPick(path); dismiss() }.fontWeight(.semibold)
                }
            }
            .task { await load(path) }
        }
    }

    private func load(_ p: String) async {
        loading = true; defer { loading = false }
        path = p
        let items = (try? await storage.list(p)) ?? []
        dirs = items.filter { $0.isDirectory }
    }

    private func up() async {
        let root = storage.channel == .usb ? "/ext" : "/"
        guard path != root else { return }
        let parent = (path as NSString).deletingLastPathComponent
        await load(parent.isEmpty ? root : parent)
    }
}
