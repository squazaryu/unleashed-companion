import Foundation
import CryptoKit
import Combine

enum TransferChannel: String, Codable, Equatable {
    case ble
    case usb

    var label: String {
        switch self {
        case .ble: return "BLE"
        case .usb: return "USB SD"
        }
    }

    var systemImage: String {
        switch self {
        case .ble: return "bluetooth"
        case .usb: return "cable.connector"
        }
    }
}

protocol DeviceFileStore {
    var channel: TransferChannel { get }

    func list(_ path: String) async throws -> [FlipperFile]
    func read(_ path: String) async throws -> Data
    func write(
        _ path: String,
        data: Data,
        progress: (@Sendable (Int) -> Void)?
    ) async throws
    func makeDirectory(_ path: String) async throws
    func delete(_ path: String, recursive: Bool) async throws
    func move(_ from: String, to newPath: String) async throws
    func md5(_ path: String) async -> String?
    func exists(_ path: String) async -> Bool
    func uploadFolder(
        localURL: URL,
        to destination: String,
        progress: @escaping (UploadProgress) -> Void
    ) async throws
}

extension DeviceFileStore {
    func write(_ path: String, data: Data) async throws {
        try await write(path, data: data, progress: nil)
    }

    func delete(_ path: String) async throws {
        try await delete(path, recursive: false)
    }

    func uploadFolder(
        localURL: URL,
        to destination: String,
        progress: @escaping (UploadProgress) -> Void
    ) async throws {
        let fm = FileManager.default
        var fileURLs: [URL] = []
        var totalBytes = 0
        if let enumerator = fm.enumerator(
            at: localURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) {
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values.isRegularFile == true {
                    fileURLs.append(url)
                    totalBytes += values.fileSize ?? 0
                }
            }
        }

        var state = UploadProgress(
            filesTotal: fileURLs.count,
            bytesTotal: totalBytes,
            channel: channel
        )
        progress(state)

        try await makeDirectory(destination)
        let rootName = localURL.lastPathComponent
        let base = destination.hasSuffix("/") ? String(destination.dropLast()) : destination
        let rootRemote = "\(base)/\(rootName)"
        try await makeDirectory(rootRemote)

        for url in fileURLs {
            let relativePath = url.path
                .replacingOccurrences(of: localURL.path, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let remotePath = "\(rootRemote)/\(relativePath)"

            let components = remotePath.split(separator: "/").dropLast()
            var current = ""
            for component in components {
                current += "/\(component)"
                if current != rootRemote && current.hasPrefix(rootRemote) {
                    try await makeDirectory(current)
                }
            }

            state.currentFile = relativePath
            progress(state)
            let data = try Data(contentsOf: url)
            try await write(remotePath, data: data)
            state.filesDone += 1
            state.bytesDone += data.count
            progress(state)
        }

        state.finished = true
        progress(state)
    }
}

extension FlipperStorage: DeviceFileStore {
    var channel: TransferChannel { .ble }
}

final class USBSDStorage: DeviceFileStore {
    enum USBStorageError: LocalizedError {
        case unsupportedPath(String)
        case notFlipperSD
        case destinationExists(String)
        case disconnected

        var errorDescription: String? {
            switch self {
            case .unsupportedPath(let path):
                return "USB SD mode can only access /ext paths, not \(path)."
            case .notFlipperSD:
                return "Selected folder does not look like a Flipper SD card."
            case .destinationExists(let path):
                return "Destination already exists: \(path)."
            case .disconnected:
                return "USB SD card is no longer reachable. Reconnect the cable and open USB SD Mode on the Flipper."
            }
        }
    }

    let channel: TransferChannel = .usb
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    var displayName: String { rootURL.lastPathComponent.isEmpty ? "USB SD" : rootURL.lastPathComponent }

    func validateRoot() throws {
        try withAccess {
            let names = Set((try FileManager.default.contentsOfDirectory(atPath: rootURL.path)))
            let markers = ["apps", "apps_data", "update", "subghz", "infrared", "badusb", "nfc"]
            let hits = markers.filter { names.contains($0) }.count
            if hits < 2 {
                throw USBStorageError.notFlipperSD
            }
        }
    }

    /// True while the SD root is still reachable; false once USB SD Mode ends on the
    /// Flipper or the cable is unplugged. Used to detect a mid-session disconnect.
    func reachable() -> Bool {
        (try? withAccess {
            _ = try FileManager.default.contentsOfDirectory(atPath: rootURL.path)
            return true
        }) ?? false
    }

    func list(_ path: String) async throws -> [FlipperFile] {
        try withAccess {
            let url = try localURL(for: path)
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
            let urls = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: []
            )
            return urls.map { child in
                let values = try? child.resourceValues(forKeys: keys)
                let isDirectory = values?.isDirectory ?? false
                let size = UInt32(clamping: values?.fileSize ?? 0)
                let remote = path == "/ext" ? "/ext/\(child.lastPathComponent)" : "\(path)/\(child.lastPathComponent)"
                return FlipperFile(
                    name: child.lastPathComponent,
                    path: remote,
                    isDirectory: isDirectory,
                    size: size
                )
            }.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    func read(_ path: String) async throws -> Data {
        try withAccess {
            try Data(contentsOf: try localURL(for: path))
        }
    }

    func write(
        _ path: String,
        data: Data,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws {
        try withAccess {
            let url = try localURL(for: path)
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            progress?(0)

            // Stream into a temp file in chunks so the UI gets real progress on large
            // files, then atomically swap it into place (no half-written final file).
            let tmp = dir.appendingPathComponent(".\(UUID().uuidString).tmp")
            guard FileManager.default.createFile(atPath: tmp.path, contents: nil) else {
                try data.write(to: url, options: .atomic)   // fallback: one-shot atomic
                progress?(data.count)
                return
            }
            do {
                let handle = try FileHandle(forWritingTo: tmp)
                let chunk = 256 * 1024
                var offset = 0
                while offset < data.count {
                    let end = min(offset + chunk, data.count)
                    try handle.write(contentsOf: data[offset..<end])
                    offset = end
                    progress?(offset)
                }
                try handle.close()
                if FileManager.default.fileExists(atPath: url.path) {
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
                } else {
                    try FileManager.default.moveItem(at: tmp, to: url)
                }
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                throw error
            }
            progress?(data.count)
        }
    }

    func makeDirectory(_ path: String) async throws {
        try withAccess {
            try FileManager.default.createDirectory(
                at: try localURL(for: path),
                withIntermediateDirectories: true
            )
        }
    }

    func delete(_ path: String, recursive: Bool = false) async throws {
        try withAccess {
            try FileManager.default.removeItem(at: try localURL(for: path))
        }
    }

    func move(_ from: String, to newPath: String) async throws {
        try withAccess {
            let src = try localURL(for: from)
            let dst = try localURL(for: newPath)
            if FileManager.default.fileExists(atPath: dst.path) {
                throw USBStorageError.destinationExists(newPath)
            }
            try FileManager.default.createDirectory(
                at: dst.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: src, to: dst)
        }
    }

    func md5(_ path: String) async -> String? {
        guard let data = try? await read(path) else { return nil }
        return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func exists(_ path: String) async -> Bool {
        (try? withAccess {
            FileManager.default.fileExists(atPath: try localURL(for: path).path)
        }) ?? false
    }

    private func withAccess<T>(_ body: () throws -> T) throws -> T {
        let scoped = rootURL.startAccessingSecurityScopedResource()
        defer { if scoped { rootURL.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    func localURL(for path: String) throws -> URL {
        if path == "/" || path == "/ext" { return rootURL }
        guard path.hasPrefix("/ext/") else {
            throw USBStorageError.unsupportedPath(path)
        }

        let relative = path.dropFirst("/ext/".count)
        var url = rootURL
        for component in relative.split(separator: "/") {
            guard component != "." && component != ".." else {
                throw USBStorageError.unsupportedPath(path)
            }
            url.appendPathComponent(String(component))
        }
        return url
    }
}

@MainActor
final class TransferChannelStore: ObservableObject {
    static let shared = TransferChannelStore()
    private static let usbBookmarkKey = "transfer.usbRootBookmark.v1"

    @Published private(set) var usbRootURL: URL?
    @Published private(set) var usbRootName: String?
    @Published private(set) var lastUSBError: String?
    @Published private(set) var usbInterrupted = false   // USB dropped mid-session

    private let bleStorage = FlipperStorage()
    private var usbStorage: USBSDStorage?

    private init() {
        _ = restoreSavedUSBRoot(showError: false)
    }

    var activeChannel: TransferChannel { usbStorage == nil ? .ble : .usb }
    var hasSavedUSBRoot: Bool { UserDefaults.standard.data(forKey: Self.usbBookmarkKey) != nil }

    var activeStore: any DeviceFileStore {
        if let usbStorage { return usbStorage }
        return bleStorage
    }

    func useUSBRoot(_ url: URL) {
        do {
            let storage = USBSDStorage(rootURL: url)
            try storage.validateRoot()
            usbRootURL = url
            usbRootName = storage.displayName
            usbStorage = storage
            saveUSBBookmark(url)
            lastUSBError = nil
            usbInterrupted = false
        } catch {
            usbRootURL = nil
            usbRootName = nil
            usbStorage = nil
            lastUSBError = error.localizedDescription
        }
    }

    @discardableResult
    func restoreSavedUSBRoot(showError: Bool = true) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.usbBookmarkKey) else {
            if showError {
                lastUSBError = "Select the Flipper SD card folder first."
            }
            return false
        }

        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            let storage = USBSDStorage(rootURL: url)
            try storage.validateRoot()
            usbRootURL = url
            usbRootName = storage.displayName
            usbStorage = storage
            lastUSBError = nil
            usbInterrupted = false
            if stale { saveUSBBookmark(url) }
            return true
        } catch {
            usbRootURL = nil
            usbRootName = nil
            usbStorage = nil
            if showError {
                lastUSBError = "USB SD is not available. Open USB SD Mode on the Flipper, then select the SD card folder again."
            }
            return false
        }
    }

    func useBLE(clearSavedUSB: Bool = true) {
        usbRootURL = nil
        usbRootName = nil
        usbStorage = nil
        if clearSavedUSB {
            UserDefaults.standard.removeObject(forKey: Self.usbBookmarkKey)
        }
        lastUSBError = nil
        usbInterrupted = false
    }

    /// Detect a mid-session USB disconnect: if the active USB store is no longer
    /// reachable (cable pulled / USB SD Mode closed on the Flipper), drop it so the app
    /// falls back to BLE and flag it for the UI. Returns true if it handled a disconnect.
    @discardableResult
    func noteUSBFailureIfDisconnected() -> Bool {
        guard let usb = usbStorage, !usb.reachable() else { return false }
        usbStorage = nil
        usbRootName = nil
        usbInterrupted = true
        lastUSBError = "USB SD disconnected. Reconnect the cable and open USB SD Mode on the Flipper, then tap Reconnect — or keep using BLE."
        return true
    }

    /// Re-establish the saved USB root after a disconnect.
    @discardableResult
    func reconnectUSB() -> Bool {
        let ok = restoreSavedUSBRoot(showError: true)
        if ok { usbInterrupted = false }
        return ok
    }

    private func saveUSBBookmark(_ url: URL) {
        guard let data = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(data, forKey: Self.usbBookmarkKey)
    }
}
