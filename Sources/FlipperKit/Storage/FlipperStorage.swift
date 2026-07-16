import Foundation
import Combine

struct FlipperFile: Identifiable, Equatable {
    var id: String { path }
    let name: String
    let path: String
    let isDirectory: Bool
    let size: UInt32
}

struct UploadProgress: Equatable {
    var currentFile: String = ""
    var filesDone: Int = 0
    var filesTotal: Int = 0
    var bytesDone: Int = 0
    var bytesTotal: Int = 0
    var finished: Bool = false
    var channel: TransferChannel = .ble
}

/// High-level Flipper SD storage operations built on the RPC session.
/// Handles streaming reads/writes and recursive folder upload — the key
/// "upload whole folders, not one file at a time" requirement.
final class FlipperStorage {
    let rpc: FlipperRPC
    /// Max payload per WriteRequest chunk. Stays well under BLE/serial limits.
    private let chunkSize = 512

    /// Fires (with the written path) after every successful write/upload, so
    /// any list view showing device contents can re-sync itself. Shared across
    /// all FlipperStorage instances since views and the updater each make their
    /// own. Delivered on the main run loop.
    static let didChange = PassthroughSubject<String, Never>()

    init(rpc: FlipperRPC = .shared) { self.rpc = rpc }

    // MARK: - Listing

    func list(_ path: String) async throws -> [FlipperFile] {
        let responses = try await rpc.command { main in
            main.content = .storageListRequest({
                var r = PBStorage_ListRequest()
                r.path = path
                return r
            }())
        }
        var files: [FlipperFile] = []
        for r in responses {
            if case .storageListResponse(let lr) = r.content {
                for f in lr.file {
                    let isDir = f.type == .dir
                    let full = path == "/" ? "/\(f.name)" : "\(path)/\(f.name)"
                    files.append(FlipperFile(name: f.name, path: full,
                                             isDirectory: isDir, size: f.size))
                }
            }
        }
        return files.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// On-device md5 of a file, or nil if it doesn't exist / errors.
    func md5(_ path: String) async -> String? {
        do {
            let responses = try await rpc.command(timeout: 20) { main in
                main.content = .storageMd5SumRequest({
                    var r = PBStorage_Md5sumRequest(); r.path = path; return r
                }())
            }
            for r in responses {
                if case .storageMd5SumResponse(let mr) = r.content {
                    return mr.md5Sum.isEmpty ? nil : mr.md5Sum
                }
            }
        } catch { /* missing file or RPC error → treat as absent */ }
        return nil
    }

    /// File modification time (Unix seconds), or nil on error.
    func timestamp(_ path: String) async -> UInt32? {
        do {
            let responses = try await rpc.command(timeout: 15) { main in
                main.content = .storageTimestampRequest({
                    var r = PBStorage_TimestampRequest(); r.path = path; return r
                }())
            }
            for r in responses {
                if case .storageTimestampResponse(let tr) = r.content { return tr.timestamp }
            }
        } catch { }
        return nil
    }

    /// True only when Storage Stat confirms a file or directory. Do not derive
    /// existence from Timestamp: current firmware can return a stale timestamp for
    /// a missing FAT path while Stat and MD5 correctly report NOT_EXIST.
    func exists(_ path: String) async -> Bool {
        do {
            let responses = try await rpc.command(timeout: 15) { main in
                main.content = .storageStatRequest({
                    var r = PBStorage_StatRequest(); r.path = path; return r
                }())
            }
            for response in responses {
                if case .storageStatResponse(let stat) = response.content {
                    return stat.hasFile
                }
            }
        } catch { }
        return false
    }

    func makeDirectory(_ path: String) async throws {
        do {
            _ = try await rpc.command { main in
                main.content = .storageMkdirRequest({
                    var r = PBStorage_MkdirRequest(); r.path = path; return r
                }())
            }
        } catch FlipperRPCError.status(let s) where s == .errorStorageExist {
            // Directory already exists — fine for recursive upload.
        }
    }

    func delete(_ path: String, recursive: Bool = false) async throws {
        // Recursive deletes (staging / rollback trees) can touch many files; give the
        // device generous time so a busy SD doesn't trip the default 30 s ceiling.
        _ = try await rpc.command(timeout: 90) { main in
            main.content = .storageDeleteRequest({
                var r = PBStorage_DeleteRequest(); r.path = path; r.recursive = recursive; return r
            }())
        }
        let p = path
        DispatchQueue.main.async { Self.didChange.send(p) }
    }

    /// Move / rename a file or folder (Flipper `storage rename` = move when the
    /// destination is in another directory). Same-SD only; destination dir must exist.
    func move(_ from: String, to newPath: String) async throws {
        // Flipper `rename` is copy + remove on the SD, so a large file (≈300 KB) over a
        // loaded BLE link can exceed the default 30 s ceiling. Give it room — this was a
        // cause of "command timed out" mid-install.
        _ = try await rpc.command(timeout: 90) { main in
            main.content = .storageRenameRequest({
                var r = PBStorage_RenameRequest(); r.oldPath = from; r.newPath = newPath; return r
            }())
        }
        let np = newPath
        DispatchQueue.main.async { Self.didChange.send(np) }
    }

    // MARK: - Read

    func read(_ path: String) async throws -> Data {
        let responses = try await rpc.command(timeout: 120) { main in
            main.content = .storageReadRequest({
                var r = PBStorage_ReadRequest(); r.path = path; return r
            }())
        }
        var data = Data()
        for r in responses {
            if case .storageReadResponse(let rr) = r.content {
                data.append(rr.file.data)
            }
        }
        return data
    }

    // MARK: - Write

    /// Write `data` to `path` in chunks. `progress` is called with the running
    /// number of bytes pushed to the Flipper (for a live progress bar).
    func write(_ path: String, data: Data,
               progress: (@Sendable (Int) -> Void)? = nil) async throws {
        var configures: [(inout PB_Main) -> Void] = []
        var offset = 0
        repeat {
            let end = min(offset + chunkSize, data.count)
            let chunk = data.subdata(in: offset..<end)
            configures.append { main in
                main.content = .storageWriteRequest({
                    var r = PBStorage_WriteRequest()
                    r.path = path
                    var file = PBStorage_File()
                    file.data = chunk
                    r.file = file
                    return r
                }())
            }
            offset = end
        } while offset < data.count

        if configures.isEmpty {           // empty file
            configures.append { main in
                main.content = .storageWriteRequest({
                    var r = PBStorage_WriteRequest(); r.path = path
                    r.file = PBStorage_File(); return r
                }())
            }
        }
        let total = data.count
        let chunk = chunkSize
        // 60s is a STALL threshold (resets on every chunk ack), not a ceiling on total
        // duration — see commandStreaming's doc comment. A large file (several MB, e.g.
        // an ESP32 flasher .fap) can take minutes end to end without ever going 60s
        // without progress; a genuinely dead link is still caught within ~60s of going
        // quiet, same as before this used to be a single fixed 300s ceiling on the whole
        // transfer (which large files could exceed even while healthy).
        _ = try await rpc.commandStreaming(timeout: 60, onFrameSent: { sent in
            progress?(min(sent * chunk, total))
        }, configures)
        progress?(total)
        let p = path
        DispatchQueue.main.async { Self.didChange.send(p) }
    }

    // MARK: - Recursive folder upload

    /// Upload an entire local directory tree to `destination` on the Flipper,
    /// creating subdirectories as needed and reporting progress.
    func uploadFolder(localURL: URL, to destination: String,
                      progress: @escaping (UploadProgress) -> Void) async throws {
        let fm = FileManager.default
        var fileURLs: [URL] = []
        var totalBytes = 0
        if let en = fm.enumerator(at: localURL, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for case let url as URL in en {
                let vals = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if vals.isRegularFile == true {
                    fileURLs.append(url)
                    totalBytes += vals.fileSize ?? 0
                }
            }
        }

        var state = UploadProgress(filesTotal: fileURLs.count, bytesTotal: totalBytes, channel: channel)
        progress(state)

        try await makeDirectory(destination)
        let rootName = localURL.lastPathComponent
        let base = destination.hasSuffix("/") ? String(destination.dropLast()) : destination
        let rootRemote = "\(base)/\(rootName)"
        try await makeDirectory(rootRemote)

        for url in fileURLs {
            let rel = url.path.replacingOccurrences(of: localURL.path, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let remotePath = "\(rootRemote)/\(rel)"

            // Ensure intermediate directories exist.
            let comps = remotePath.split(separator: "/").dropLast()
            var acc = ""
            for c in comps {
                acc += "/\(c)"
                if acc != rootRemote && acc.hasPrefix(rootRemote) {
                    try await makeDirectory(acc)
                }
            }

            state.currentFile = rel
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
