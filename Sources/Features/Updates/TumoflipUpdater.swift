import Foundation
import CryptoKit

// MARK: - Injectable seams (so the orchestrator is unit-testable without hardware)

/// Minimal device filesystem the installer needs. Backed by `FlipperStorage` in the
/// app; faked in tests.
protocol TumoflipDeviceFS {
    func write(_ data: Data, to path: String) async throws
    func read(_ path: String) async -> Data?
    func deviceMD5(_ path: String) async -> String?
    func checkedDeviceMD5(_ path: String) async throws -> String?
    func move(_ from: String, to: String) async throws
    func delete(_ path: String) async throws
    func deleteTree(_ path: String) async throws
    func makeDirectory(_ path: String) async throws
    func exists(_ path: String) async -> Bool
}

extension TumoflipDeviceFS {
    /// Compatibility fallback for test doubles and non-RPC stores. Live adapters
    /// override this so a missing file can be distinguished from a transport error.
    func checkedDeviceMD5(_ path: String) async throws -> String? {
        await deviceMD5(path)
    }
}

/// Yields the bytes for a manifest `source` path (from the downloaded package zip).
protocol TumoflipPackageSource {
    func bytes(for source: String) async throws -> Data
}

// MARK: - Errors + hashing

enum TumoflipInstallError: Error, Equatable {
    case sourceMissing(String)
    case hashMismatch(String)
    case deviceVerifyFailed(String)
    case incompatible(String)            // device firmware/api/target vs manifest
    case rollbackIncomplete([String])    // targets that could NOT be restored
    case statePersistenceFailed(String)
    case activeAppCouldNotStop
    case cancelled                       // user pressed Stop → transaction rolled back to the prior state
}

/// Thread-safe stop flag. `TumoflipInstaller.install` runs off the main actor and
/// polls this at file/op boundaries; the UI sets it from the main actor via
/// `TumoflipUpdaterService.requestStop()`. Checked once per file (not per chunk),
/// so a plain lock is cheap and keeps it `Sendable`-safe. It is only ever read at a
/// SAFE boundary — never mid-write of a live file — so a stopped install rolls back
/// cleanly and never leaves a truncated app.
final class StopToken: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    func reset() { lock.lock(); stopped = false; lock.unlock() }
}

enum TumoflipHash {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Device compatibility

enum TumoflipCompat {
    /// Fail closed unless the connected device exactly matches the package release.
    static func check(deviceTarget: Int?, deviceAPI: String?,
                      deviceVersion: String?, deviceOriginFork: String? = nil,
                      manifest: TumoflipManifest) throws {
        guard let dt = deviceTarget else {
            throw TumoflipInstallError.incompatible("device target is unavailable")
        }
        guard let deviceAPI, !deviceAPI.isEmpty else {
            throw TumoflipInstallError.incompatible("device firmware API is unavailable")
        }
        guard let deviceVersion, !deviceVersion.isEmpty else {
            throw TumoflipInstallError.incompatible("device firmware version is unavailable")
        }
        guard deviceOriginFork?.caseInsensitiveCompare("tumoflip") == .orderedSame else {
            let origin = deviceOriginFork?.isEmpty == false ? deviceOriginFork! : "unknown"
            throw TumoflipInstallError.incompatible("device firmware origin is \(origin), expected tumoflip")
        }
        if dt != manifest.firmware.target {
            throw TumoflipInstallError.incompatible("device is f\(dt), packages are for f\(manifest.firmware.target)")
        }
        if deviceAPI != manifest.firmware.api {
            throw TumoflipInstallError.incompatible(
                "device API \(deviceAPI) ≠ package API \(manifest.firmware.api)")
        }
        if deviceVersion != manifest.firmware.version {
            throw TumoflipInstallError.incompatible(
                "device firmware \(deviceVersion) ≠ package firmware \(manifest.firmware.version)")
        }
    }
}

// MARK: - Persisted state (durable ledger + in-flight write-ahead transaction)

/// Whole persisted state, written atomically (temp + rename). Holds the cumulative
/// install ledger and at most one in-flight transaction journal.
struct TumoflipState: Codable, Equatable {
    var generation: UInt64 = 0
    var ledger: [String: LedgerEntry] = [:]   // target -> what is durably installed there
    var txn: TumoflipJournal?                  // present only mid-transaction

    struct LedgerEntry: Codable, Equatable {
        let sha256: String
        let md5: String
        let releaseId: String
    }
}

/// Write-ahead transaction journal. The FULL set of operations is persisted before any
/// destructive move, and each op's state is advanced as it completes, so recovery can
/// reconstruct and undo a partially-applied transaction by cross-checking actual files.
struct TumoflipJournal: Codable, Equatable {
    enum Phase: String, Codable { case staging, activating, committed, rolledBack }
    let releaseId: String
    let fingerprint: String
    let groups: [String]
    var phase: Phase
    var ops: [FileOp]
    var cleanups: [CleanupOp]

    struct FileOp: Codable, Equatable {
        let target: String
        let stage: String
        let backup: String
        let sha256: String
        var md5: String                  // filled at stage time
        var originalMD5: String? = nil
        var hadOriginal: Bool? = nil
        var state: State
        enum State: String, Codable {
            case planned, staged, unchanged, backupPlanned, backedUp, activationPlanned, activated
        }
    }
    struct CleanupOp: Codable, Equatable {
        let legacy: String
        let backup: String               // legacy is MOVED here, never deleted
        var md5: String? = nil
        var state: State = .planned
        enum State: String, Codable { case planned, movePlanned, movedAside }
    }
}

private struct TumoflipStateEnvelope: Codable {
    let version: Int
    let checksum: String
    let state: TumoflipState
}

private struct TumoflipCompatibilityState: Codable {
    struct File: Codable {
        let target: String
        let sha256: String
    }

    let schema: Int
    let releaseId: String
    let transaction: String
    let groups: [String]
    let files: [File]
    let rollback: String

    enum CodingKeys: String, CodingKey {
        case schema, transaction, groups, files, rollback
        case releaseId = "release_id"
    }
}

// MARK: - Orchestrator

/// Atomic, crash-consistent, rollback-safe installer for one tumoflip package set.
struct TumoflipInstaller {
    static let root = "/ext/.tumoflip"
    static let stateSlotA = "\(root)/install-state.a.json"
    static let stateSlotB = "\(root)/install-state.b.json"

    enum Outcome: Equatable {
        case installed(files: Int, legacyMovedAside: Int)
        case alreadyInstalled
    }

    let fs: TumoflipDeviceFS
    let source: TumoflipPackageSource

    private func txnDir(_ fp: String) -> String { String(fp.prefix(16)) }
    private func stageDir(_ fp: String) -> String { "\(Self.root)/staging/\(txnDir(fp))" }
    private func rollbackDir(_ fp: String) -> String { "\(Self.root)/rollback/\(txnDir(fp))" }
    private func flat(_ target: String) -> String {
        TumoflipHash.sha256(Data(target.utf8))
    }
    static func shortName(_ target: String) -> String { (target as NSString).lastPathComponent }
    private func parentDir(_ path: String) -> String {
        guard let i = path.lastIndex(of: "/") else { return path }
        return String(path[path.startIndex..<i])
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func encodeStateSlot(_ state: TumoflipState) throws -> Data {
        let stateData = try encoder().encode(state)
        let envelope = TumoflipStateEnvelope(
            version: 1, checksum: TumoflipHash.sha256(stateData), state: state)
        return try encoder().encode(envelope)
    }

    static func decodeStateSlot(_ data: Data) -> TumoflipState? {
        guard let envelope = try? JSONDecoder().decode(TumoflipStateEnvelope.self, from: data),
              envelope.version == 1,
              let stateData = try? encoder().encode(envelope.state),
              TumoflipHash.sha256(stateData) == envelope.checksum else { return nil }
        return envelope.state
    }

    private func loadState() async throws -> TumoflipState? {
        var states: [TumoflipState] = []
        var sawStateFile = false
        for path in [Self.stateSlotA, Self.stateSlotB] {
            if let data = await fs.read(path) {
                sawStateFile = true
                if let state = Self.decodeStateSlot(data) { states.append(state) }
            }
        }
        if states.isEmpty, sawStateFile {
            throw TumoflipInstallError.statePersistenceFailed("both state slots are invalid")
        }
        return states.max { $0.generation < $1.generation }
    }

    /// Durable state write for a filesystem whose rename is copy+remove, not atomic.
    /// Alternate slots keep the previous valid generation intact during a torn write.
    private func saveState(_ state: inout TumoflipState) async throws {
        state.generation &+= 1
        let data = try Self.encodeStateSlot(state)
        let path = state.generation.isMultiple(of: 2) ? Self.stateSlotA : Self.stateSlotB
        try await fs.makeDirectory(Self.root)
        try await fs.write(data, to: path)
        guard await fs.deviceMD5(path) == TumoflipHash.md5(data) else {
            throw TumoflipInstallError.statePersistenceFailed(path)
        }
    }

    /// True only when every file in the plan is recorded in the ledger with the SAME
    /// content hash, still verifies on the device, and no declared legacy path remains.
    /// This keeps exact repeats as no-ops while allowing cleanup-only manifest updates
    /// to run even when the canonical package files are already current.
    private func allInstalled(_ plan: TumoflipInstallPlan, _ state: TumoflipState) async -> Bool {
        for f in plan.files {
            guard let e = state.ledger[f.target], e.sha256 == f.sha256 else { return false }
            guard await fs.deviceMD5(f.target) == e.md5 else { return false }
        }
        for cleanup in plan.cleanup where await fs.exists(cleanup.legacy) {
            return false
        }
        return true
    }

    /// Recover the persisted state if a prior transaction was interrupted: roll it back.
    /// Throws `rollbackIncomplete` if the filesystem can't be fully restored.
    func recover() async throws {
        guard var state = try await loadState(), let txn = state.txn,
              txn.phase == .staging || txn.phase == .activating else { return }
        try await rollback(&state, txn)
    }

    // MARK: - Up-to-date / divergence status

    /// Per-group installed status, derived from the durable ledger vs the latest manifest.
    enum GroupStatus: String, Equatable { case upToDate, updateAvailable, notInstalled, empty }

    /// Device-backed status for one package target. Transport failures are deliberately
    /// distinct from a missing file so a brief reconnect never becomes a false reinstall.
    enum FileStatus: String, Equatable, Hashable {
        case upToDate
        case needsUpdate
        case missing
        case unknown
        case validationError
    }

    struct StatusSnapshot: Equatable {
        let groups: [String: GroupStatus]
        let files: [String: FileStatus]
        let pendingCleanup: [String: [TumoflipManifest.CleanupEntry]]
    }

    /// The durable install ledger (target → what is recorded as installed). Empty if
    /// nothing is installed or the device is unreachable.
    func currentLedger() async throws -> [String: TumoflipState.LedgerEntry] {
        (try await loadState())?.ledger ?? [:]
    }

    /// Refresh the schema-v1 compatibility snapshot consumed by firmware diagnostics
    /// and older host tooling. The transactional source of truth remains the two-slot
    /// ledger above; these files are a committed, human-readable projection of it.
    func refreshCompatibilityState(manifest: TumoflipManifest,
                                   plan: TumoflipInstallPlan) async throws {
        let (stateData, packageData) = try compatibilityPayload(manifest: manifest, plan: plan)

        try await fs.makeDirectory(Self.root)
        try await fs.write(stateData, to: Self.compatibilityStatePath)
        guard await fs.deviceMD5(Self.compatibilityStatePath) == TumoflipHash.md5(stateData) else {
            throw TumoflipInstallError.statePersistenceFailed(Self.compatibilityStatePath)
        }
        try await fs.write(packageData, to: Self.packageStatePath)
        guard await fs.deviceMD5(Self.packageStatePath) == TumoflipHash.md5(packageData) else {
            throw TumoflipInstallError.statePersistenceFailed(Self.packageStatePath)
        }
    }

    private static let compatibilityStatePath = "\(root)/install-state.json"
    private static let packageStatePath = "\(root)/package-state.txt"

    private func compatibilityPayload(manifest: TumoflipManifest,
                                      plan: TumoflipInstallPlan) throws -> (Data, Data) {
        let transaction = "\(plan.releaseId.prefix(16))-\(plan.fingerprint.prefix(8))"
        let rollback = "/.tumoflip/rollback/\(transaction)"
        let state = TumoflipCompatibilityState(
            schema: 1,
            releaseId: plan.releaseId,
            transaction: transaction,
            groups: plan.groups,
            files: plan.files.map { .init(target: $0.target, sha256: $0.sha256) },
            rollback: rollback
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var stateData = try encoder.encode(state)
        stateData.append(0x0A)

        let packageState = [
            "Filetype: Tumoflip Package State",
            "Version: 1",
            "Schema: 2",
            "ReleaseId: \(plan.releaseId)",
            "Transaction: \(transaction)",
            "Firmware: \(manifest.firmware.version)",
            "FirmwareApi: \(manifest.firmware.api)",
            "PackageRelease: firmware",
            "Groups: \(plan.groups.joined(separator: ","))",
            "InstalledFiles: \(plan.files.count)",
            "CleanupCandidates: \(plan.cleanup.count)",
            "Rollback: \(rollback)",
            "",
        ].joined(separator: "\n")
        let packageData = Data(packageState.utf8)
        return (stateData, packageData)
    }

    /// Pure ledger↔manifest comparison for one group, by CONTENT HASH (not the release
    /// tag), so a partially-installed or locally-changed file is correctly flagged:
    ///   • empty          — the group has no files in this manifest;
    ///   • notInstalled   — none of the group's targets are recorded;
    ///   • upToDate       — every target is recorded with the manifest's sha256;
    ///   • updateAvailable — recorded, but at least one target differs or is missing.
    static func groupStatus(for group: String, manifest: TumoflipManifest,
                            ledger: [String: TumoflipState.LedgerEntry]) -> GroupStatus {
        guard let plan = try? TumoflipInstallPlan.make(manifest: manifest, groups: [group]),
              !plan.files.isEmpty else { return .empty }
        var inLedger = 0, matched = 0
        for f in plan.files {
            guard let entry = ledger[f.target] else { continue }
            inLedger += 1
            if entry.sha256 == f.sha256 { matched += 1 }
        }
        if inLedger == 0 { return .notInstalled }
        return matched == plan.files.count ? .upToDate : .updateAvailable
    }

    /// Device-backed verification of one group: confirms each target is physically
    /// present and its on-device MD5 still matches what the ledger recorded (which in
    /// turn matched the manifest sha256 at install time). Unlike `groupStatus`, this
    /// catches files deleted, corrupted, or changed on the SD outside the app — the
    /// cases the ledger snapshot alone can't see. Slower (an MD5 per file over BLE), so
    /// it's meant to run on demand, not on every screen open.
    func verifyGroupOnDevice(_ group: String, manifest: TumoflipManifest,
                             ledger: [String: TumoflipState.LedgerEntry]) async -> GroupStatus {
        guard let plan = try? TumoflipInstallPlan.make(manifest: manifest, groups: [group]),
              !plan.files.isEmpty else { return .empty }
        var inLedger = 0, verified = 0
        for f in plan.files {
            guard let entry = ledger[f.target], entry.sha256 == f.sha256 else { continue }
            inLedger += 1
            if await fs.deviceMD5(f.target) == entry.md5 { verified += 1 }   // present + intact
        }
        if inLedger == 0 { return .notInstalled }
        return verified == plan.files.count ? .upToDate : .updateAvailable
    }

    /// Refresh package status and safely adopt files installed by a full firmware
    /// resource sync. Adoption is allowed only for a complete group whose manifest
    /// supplies an expected MD5 for every target and whose device hashes all match.
    /// Legacy manifests remain ledger-only. Pending cleanup always means update.
    func reconcileStatus(manifest: TumoflipManifest) async throws -> [String: GroupStatus] {
        try await reconcileStatus(manifest: manifest, captureValidationErrors: false).groups
    }

    /// Detailed reconciliation used by FW Packages. It preserves the existing group
    /// aggregate while exposing the exact file that is current, changed, missing, or
    /// temporarily unverifiable. Complete-MD5 manifests remain device-authoritative.
    func reconcilePackageStatus(manifest: TumoflipManifest) async throws -> StatusSnapshot {
        try await reconcileStatus(manifest: manifest, captureValidationErrors: true)
    }

    private func reconcileStatus(
        manifest: TumoflipManifest,
        captureValidationErrors: Bool
    ) async throws -> StatusSnapshot {
        var state = try await loadState() ?? TumoflipState()
        let originalLedger = state.ledger
        var statuses: [String: GroupStatus] = [:]
        var fileStatuses: [String: FileStatus] = [:]
        var pendingCleanup: [String: [TumoflipManifest.CleanupEntry]] = [:]
        var currentGroups = Set<String>()

        for group in TumoflipManifest.knownGroups {
            guard let plan = try? TumoflipInstallPlan.make(manifest: manifest, groups: [group]),
                  !plan.files.isEmpty else {
                statuses[group] = .empty
                continue
            }

            let groupCleanup = await pendingCleanupEntries(plan)
            if !groupCleanup.isEmpty {
                pendingCleanup[group] = groupCleanup
            }
            let cleanupPending = !groupCleanup.isEmpty
            let ledgerStatus = Self.groupStatus(for: group, manifest: manifest, ledger: state.ledger)
            // Legacy manifests have no device-verifiable expected content. Preserve
            // their conservative ledger-only policy, including the cleanup guard.
            guard plan.files.allSatisfy({ $0.md5 != nil }) else {
                if captureValidationErrors {
                    for file in plan.files {
                        do {
                            guard let actual = try await checkedDeviceMD5(file.target) else {
                                fileStatuses[file.target] = .missing
                                continue
                            }
                            guard let entry = state.ledger[file.target] else {
                                fileStatuses[file.target] = .unknown
                                continue
                            }
                            fileStatuses[file.target] =
                                entry.sha256 == file.sha256 && entry.md5 == actual
                                ? .upToDate : .needsUpdate
                        } catch {
                            fileStatuses[file.target] = .validationError
                        }
                    }
                }
                statuses[group] = cleanupPending ? .updateAvailable : ledgerStatus
                if ledgerStatus == .upToDate, !cleanupPending { currentGroups.insert(group) }
                continue
            }

            // A complete MD5 manifest makes the device authoritative for status even
            // when the ledger already looks current. Missing or changed targets must
            // never inherit an Up-to-date badge from ledger metadata alone.
            var allMatch = !cleanupPending
            var validationFailed = false
            var knownDivergence = cleanupPending
            for file in plan.files {
                do {
                    let actual = try await checkedDeviceMD5(file.target)
                    if actual == nil {
                        fileStatuses[file.target] = .missing
                        allMatch = false
                        knownDivergence = true
                    } else if actual == file.md5 {
                        fileStatuses[file.target] = .upToDate
                    } else {
                        fileStatuses[file.target] = .needsUpdate
                        allMatch = false
                        knownDivergence = true
                    }
                } catch {
                    guard captureValidationErrors else { throw error }
                    fileStatuses[file.target] = .validationError
                    validationFailed = true
                    allMatch = false
                }
            }
            guard allMatch else {
                // Keep the prior conservative aggregate during a transport failure.
                // The affected row still explains that validation, rather than file
                // presence, failed.
                statuses[group] = validationFailed && !knownDivergence
                    ? ledgerStatus : .updateAvailable
                continue
            }

            for file in plan.files {
                state.ledger[file.target] = .init(
                    sha256: file.sha256, md5: file.md5!, releaseId: manifest.releaseId)
            }
            statuses[group] = .upToDate
            currentGroups.insert(group)
        }

        let ledgerChanged = state.ledger != originalLedger
        var currentPlan: TumoflipInstallPlan?
        var projectionChanged = false
        if !currentGroups.isEmpty {
            let plan = try TumoflipInstallPlan.make(manifest: manifest, groups: currentGroups)
            currentPlan = plan
            let expected = try compatibilityPayload(manifest: manifest, plan: plan)
            let currentCompatibility = await fs.read(Self.compatibilityStatePath)
            let currentPackageState = await fs.read(Self.packageStatePath)
            projectionChanged = currentCompatibility != expected.0 || currentPackageState != expected.1
        }

        guard ledgerChanged || projectionChanged else {
            return StatusSnapshot(
                groups: statuses,
                files: fileStatuses,
                pendingCleanup: pendingCleanup
            )
        }

        // Keep the compatibility projection aligned with every complete group, not
        // merely the last group encountered during adoption. Write it before the
        // authoritative ledger so a projection failure leaves adoption retryable.
        if let currentPlan, projectionChanged {
            try await refreshCompatibilityState(manifest: manifest, plan: currentPlan)
        }
        if ledgerChanged {
            try await saveState(&state)
        }
        return StatusSnapshot(
            groups: statuses,
            files: fileStatuses,
            pendingCleanup: pendingCleanup
        )
    }

    private func pendingCleanupEntries(
        _ plan: TumoflipInstallPlan
    ) async -> [TumoflipManifest.CleanupEntry] {
        var entries: [TumoflipManifest.CleanupEntry] = []
        for cleanup in plan.cleanup where await fs.exists(cleanup.legacy) {
            entries.append(cleanup)
        }
        return entries
    }

    /// A brief BLE reconnect must not be interpreted as a missing package file.
    /// Retry one transport failure, then let the caller preserve its ledger fallback.
    private func checkedDeviceMD5(_ path: String) async throws -> String? {
        do {
            return try await fs.checkedDeviceMD5(path)
        } catch {
            try await Task.sleep(nanoseconds: 250_000_000)
            return try await fs.checkedDeviceMD5(path)
        }
    }

    @discardableResult
    /// `progress(done, total, label)` — `done`/`total` step over staging (first half)
    /// then activation (second half), `label` names the current file/action.
    func install(_ plan: TumoflipInstallPlan,
                 isStopRequested: @Sendable () -> Bool = { false },
                 progress: ((Int, Int, String) -> Void)? = nil) async throws -> Outcome {
        var state = try await loadState() ?? TumoflipState()

        // 0. Roll back any interrupted transaction before starting a new one.
        if let txn = state.txn, txn.phase == .staging || txn.phase == .activating {
            try await rollback(&state, txn)
        }

        // 1. Idempotency — already fully installed (verified on device)?
        if await allInstalled(plan, state) { return .alreadyInstalled }

        let fp = plan.fingerprint
        let stage = stageDir(fp), rb = rollbackDir(fp)
        var journal = TumoflipJournal(
            releaseId: plan.releaseId, fingerprint: fp, groups: plan.groups, phase: .staging,
            ops: plan.files.map {
                .init(target: $0.target, stage: "\(stage)/\(flat($0.target))",
                      backup: "\(rb)/\(flat($0.target))", sha256: $0.sha256, md5: "", state: .planned)
            },
            cleanups: plan.cleanup.map {
                .init(legacy: $0.legacy, backup: "\(rb)/cleanup__\(flat($0.legacy))")
            })

        // Write-ahead: persist the FULL intent before any device write or move.
        state.txn = journal
        try await saveState(&state)

        do {
            // 2. STAGE — download, verify SHA-256, write to staging, verify on-device MD5.
            //    No live path is touched here, so any failure aborts with nothing activated.
            try await fs.makeDirectory(stage)
            for i in journal.ops.indices {
                // Stop checkpoint at a file boundary. Staging touches no live path, so
                // throwing here rolls back to a device that was never modified.
                if isStopRequested() { throw TumoflipInstallError.cancelled }
                let f = plan.files[i]
                let bytes = try await source.bytes(for: f.source)
                guard TumoflipHash.sha256(bytes) == f.sha256 else { throw TumoflipInstallError.hashMismatch(f.source) }
                try await fs.write(bytes, to: journal.ops[i].stage)
                let md5 = TumoflipHash.md5(bytes)
                guard await fs.deviceMD5(journal.ops[i].stage) == md5 else {
                    throw TumoflipInstallError.deviceVerifyFailed(f.target)
                }
                journal.ops[i].md5 = md5
                journal.ops[i].state = .staged
                state.txn = journal; try await saveState(&state)
                progress?(i + 1, 2 * journal.ops.count,
                          "Preparing " + Self.shortName(journal.ops[i].target))
            }

            // 3. ACTIVATE — back up each replaced original, then same-volume rename the
            //    staged file into place. The full plan is already journaled; per-move
            //    state advances so recovery knows how far we got.
            journal.phase = .activating
            state.txn = journal; try await saveState(&state)
            try await fs.makeDirectory(rb)
            for i in journal.ops.indices {
                // Stop checkpoint BETWEEN activations only — never inside one op's
                // backup+swap. Ops already activated (0..<i) are reverted by the
                // rollback in the catch below, so the device returns to its prior
                // working state; the op mid-swap when Stop was pressed has finished.
                if isStopRequested() { throw TumoflipInstallError.cancelled }
                progress?(journal.ops.count + i + 1, 2 * journal.ops.count,
                          "Installing " + Self.shortName(journal.ops[i].target))
                // Firmware resources may already contain these exact bytes. Record
                // them in the ledger without moving or rewriting an identical FAP;
                // this also avoids touching an executable that just exited.
                if await fs.deviceMD5(journal.ops[i].target) == journal.ops[i].md5 {
                    journal.ops[i].state = .unchanged
                    state.txn = journal; try await saveState(&state)
                    continue
                }
                if await fs.exists(journal.ops[i].target) {
                    guard let originalMD5 = await fs.deviceMD5(journal.ops[i].target) else {
                        throw TumoflipInstallError.deviceVerifyFailed(journal.ops[i].target)
                    }
                    journal.ops[i].hadOriginal = true
                    journal.ops[i].originalMD5 = originalMD5
                    journal.ops[i].state = .backupPlanned
                    state.txn = journal; try await saveState(&state)
                    try await copyRemoveVerified(
                        journal.ops[i].target, to: journal.ops[i].backup, md5: originalMD5)
                    journal.ops[i].state = .backedUp
                    state.txn = journal; try await saveState(&state)
                } else {
                    journal.ops[i].hadOriginal = false
                }
                journal.ops[i].state = .activationPlanned
                state.txn = journal; try await saveState(&state)
                try await fs.makeDirectory(parentDir(journal.ops[i].target))
                try await copyRemoveVerified(
                    journal.ops[i].stage, to: journal.ops[i].target, md5: journal.ops[i].md5)
                journal.ops[i].state = .activated
                state.txn = journal; try await saveState(&state)
            }

            // 4. CLEANUP — MOVE legacy files into the rollback area (reversible), never delete.
            for i in journal.cleanups.indices {
                if await fs.exists(journal.cleanups[i].legacy) {
                    guard let md5 = await fs.deviceMD5(journal.cleanups[i].legacy) else {
                        throw TumoflipInstallError.deviceVerifyFailed(journal.cleanups[i].legacy)
                    }
                    journal.cleanups[i].md5 = md5
                    journal.cleanups[i].state = .movePlanned
                    state.txn = journal; try await saveState(&state)
                    try await fs.makeDirectory(parentDir(journal.cleanups[i].backup))
                    try await copyRemoveVerified(
                        journal.cleanups[i].legacy, to: journal.cleanups[i].backup, md5: md5)
                    journal.cleanups[i].state = .movedAside
                    state.txn = journal; try await saveState(&state)
                }
            }

            // 5. COMMIT — record the ledger, clear the txn, atomically.
            journal.phase = .committed
            for op in journal.ops {
                state.ledger[op.target] = .init(sha256: op.sha256, md5: op.md5, releaseId: plan.releaseId)
            }
            state.txn = nil
            try await saveState(&state)
            try? await fs.deleteTree(stage)
            try? await fs.deleteTree(rb)
            return .installed(files: journal.ops.count,
                              legacyMovedAside: journal.cleanups.filter { $0.state == .movedAside }.count)
        } catch {
            // Roll back the partially-applied transaction. A rollback that can't fully
            // restore dominates the original error (data is at risk → surface that).
            do { try await rollback(&state, journal) }
            catch let rollbackError { throw rollbackError }
            throw error
        }
    }

    /// Undo a transaction, using ACTUAL filesystem presence so it's correct regardless
    /// of where the original run was interrupted. Restore failures are collected and NOT
    /// swallowed: if any file can't be restored we keep the journal recoverable and throw
    /// `rollbackIncomplete` instead of claiming success.
    private func rollback(_ state: inout TumoflipState, _ j: TumoflipJournal) async throws {
        var journal = j
        var failures: [String] = []

        // Reverse cleanup first: bring back any legacy file we moved aside.
        for i in journal.cleanups.indices.reversed()
        where journal.cleanups[i].state != .planned {
            let c = journal.cleanups[i]
            do {
                if let md5 = c.md5, await fs.deviceMD5(c.backup) == md5 {
                    if await fs.exists(c.legacy) {
                        if await fs.deviceMD5(c.legacy) == md5 {
                            try? await fs.delete(c.backup)
                        } else {
                            throw TumoflipInstallError.deviceVerifyFailed(c.legacy)
                        }
                    } else {
                        try await copyRemoveVerified(c.backup, to: c.legacy, md5: md5)
                    }
                } else if c.state == .movedAside {
                    throw TumoflipInstallError.deviceVerifyFailed(c.legacy)
                }
                journal.cleanups[i].state = .planned
            } catch { failures.append(c.legacy) }
        }

        // Reverse the file ops.
        for op in journal.ops.reversed() {
            do { try await restore(op) } catch { failures.append(op.target) }
        }

        if !failures.isEmpty {
            journal.phase = .activating          // keep it recoverable on the next attempt
            state.txn = journal
            try? await saveState(&state)
            throw TumoflipInstallError.rollbackIncomplete(failures)
        }

        journal.phase = .rolledBack
        state.txn = nil
        try await saveState(&state)
        try? await fs.deleteTree(stageDir(journal.fingerprint))
        try? await fs.deleteTree(rollbackDir(journal.fingerprint))
    }

    /// Restore one op to its pre-transaction state based on what's actually on disk.
    private func restore(_ op: TumoflipJournal.FileOp) async throws {
        // Staging never touches the live target. Treating a valid staged copy as
        // evidence that an untouched target belonged to this transaction deletes
        // user files when an earlier activation fails.
        if op.state == .planned || op.state == .staged || op.state == .unchanged { return }

        if op.hadOriginal == true, let oldMD5 = op.originalMD5 {
            let targetMD5 = await fs.deviceMD5(op.target)
            let backupMD5 = await fs.deviceMD5(op.backup)

            if targetMD5 == oldMD5 {
                if backupMD5 == oldMD5 { try? await fs.delete(op.backup) }
                return
            }
            guard backupMD5 == oldMD5 else {
                throw TumoflipInstallError.deviceVerifyFailed(op.target)
            }
            if await fs.exists(op.target) { try await fs.delete(op.target) }
            try await copyRemoveVerified(op.backup, to: op.target, md5: oldMD5)
            return
        }

        // No original existed. During activationPlanned/activated any target matching
        // our bytes (or a partial copy while the verified stage still exists) is ours.
        if await fs.exists(op.target) {
            let targetMD5 = await fs.deviceMD5(op.target)
            let stageMD5 = op.md5.isEmpty ? nil : await fs.deviceMD5(op.stage)
            let stageIsValid = stageMD5 == op.md5
            guard targetMD5 == op.md5 || stageIsValid else {
                throw TumoflipInstallError.deviceVerifyFailed(op.target)
            }
            try await fs.delete(op.target)
        }
    }

    /// Flipper RPC `storage rename` is implemented as copy + remove. Treat it as a
    /// recoverable transfer: verify the destination, then remove a surviving source.
    private func copyRemoveVerified(_ from: String, to: String, md5: String) async throws {
        var moveError: Error?
        do { try await fs.move(from, to: to) } catch { moveError = error }

        guard await fs.deviceMD5(to) == md5 else {
            if await fs.exists(to) { try? await fs.delete(to) }
            throw moveError ?? TumoflipInstallError.deviceVerifyFailed(to)
        }
        if await fs.exists(from) {
            guard await fs.deviceMD5(from) == md5 else {
                throw TumoflipInstallError.deviceVerifyFailed(from)
            }
            try await fs.delete(from)
        }
    }
}
