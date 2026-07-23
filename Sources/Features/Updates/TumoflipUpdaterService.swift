import Foundation
import ZIPFoundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Real device FS adapter (FlipperStorage)

/// Bridges `TumoflipDeviceFS` to the live Flipper over RPC.
struct FlipperDeviceFS: TumoflipDeviceFS {
    let storage = FlipperStorage()

    func write(_ data: Data, to path: String) async throws { try await storage.write(path, data: data) }
    func read(_ path: String) async -> Data? { try? await storage.read(path) }
    func deviceMD5(_ path: String) async -> String? { await storage.md5(path) }
    func checkedDeviceMD5(_ path: String) async throws -> String? {
        try await storage.checkedMD5(path)
    }
    func move(_ from: String, to: String) async throws { try await storage.move(from, to: to) }
    func delete(_ path: String) async throws { try await storage.delete(path, recursive: false) }
    func deleteTree(_ path: String) async throws { try await storage.delete(path, recursive: true) }
    func exists(_ path: String) async -> Bool { await storage.exists(path) }

    /// Recursive: create every missing ancestor (FlipperStorage.makeDirectory tolerates
    /// an existing directory), so nested staging/rollback paths come into being.
    func makeDirectory(_ path: String) async throws {
        var cur = ""
        for c in path.split(separator: "/") {
            cur += "/\(c)"
            try await storage.makeDirectory(cur)
        }
    }

}

/// USB-backed filesystem adapter. The user first selects the Flipper SD card in
/// Files, then package files are written directly into that mounted SD folder.
struct USBTumoflipDeviceFS: TumoflipDeviceFS {
    let storage: USBSDStorage

    func write(_ data: Data, to path: String) async throws { try await storage.write(path, data: data) }
    func read(_ path: String) async -> Data? { try? await storage.read(path) }
    func deviceMD5(_ path: String) async -> String? { await storage.md5(path) }
    func checkedDeviceMD5(_ path: String) async throws -> String? {
        guard await storage.exists(path) else { return nil }
        let data = try await storage.read(path)
        return TumoflipHash.md5(data)
    }
    func move(_ from: String, to: String) async throws { try await storage.move(from, to: to) }
    func delete(_ path: String) async throws { try await storage.delete(path, recursive: false) }
    func deleteTree(_ path: String) async throws { try await storage.delete(path, recursive: true) }
    func exists(_ path: String) async -> Bool { await storage.exists(path) }

    func makeDirectory(_ path: String) async throws {
        var cur = ""
        for c in path.split(separator: "/") {
            cur += "/\(c)"
            try await storage.makeDirectory(cur)
        }
    }
}

// MARK: - Zip-backed package source

/// Package bytes pre-extracted from the release `tumoflip-packages.zip`, keyed by the
/// manifest `source` path (the zip entry paths match the manifest exactly).
struct ZipPackageSource: TumoflipPackageSource {
    let entries: [String: Data]
    func bytes(for source: String) async throws -> Data {
        guard let d = entries[source] else { throw TumoflipInstallError.sourceMissing(source) }
        return d
    }

    /// Read every entry of a downloaded package zip into memory.
    static func load(zipAt url: URL) throws -> ZipPackageSource {
        guard let archive = Archive(url: url, accessMode: .read) else {
            throw TumoflipInstallError.sourceMissing("zip")
        }
        var out: [String: Data] = [:]
        for entry in archive where entry.type == .file {
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            out[entry.path] = data
        }
        return ZipPackageSource(entries: out)
    }
}

// MARK: - Service / view-model

@MainActor
final class TumoflipUpdater: ObservableObject {
    enum Phase: Equatable {
        case idle, checking, ready, downloading
        case installing(done: Int, total: Int, file: String)
        case done(String), failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var manifest: TumoflipManifest?
    @Published private(set) var releaseTag = ""
    @Published private(set) var hasPackageZip = false
    @Published private(set) var groupStatus: [String: TumoflipInstaller.GroupStatus] = [:]
    @Published private(set) var fileStatus: [String: TumoflipInstaller.FileStatus] = [:]
    @Published private(set) var pendingCleanup: [String: [TumoflipManifest.CleanupEntry]] = [:]
    @Published private(set) var transferChannel: TransferChannel = .ble
    @Published private(set) var deviceIdentity: TumoflipDeviceIdentity?
    @Published private(set) var firmwareRoute = TumoflipFirmwareRouter.route(identity: nil, manualOverride: nil)
    @Published private(set) var manualChannelOverride: TumoflipFirmwareChannel?
    /// Per-file deselection (raw manifest targets). Empty = install everything; a
    /// target here is skipped. Exclusion-based so the default (all selected) needs no
    /// manifest at init.
    @Published var excludedFiles: Set<String> = []

    /// FAP/FAL files whose embedded `.fapmeta` is incompatible with the connected
    /// firmware (target → concise reason). Populated by `validateCompatibility()` and
    /// re-checked fail-closed at install; the install action is disabled while any
    /// selected file appears here (issue #19).
    @Published private(set) var blocked: [String: String] = [:]
    @Published private(set) var validating = false
    @Published private(set) var compatibilityApiMajor: Int?
    @Published private(set) var compatibilityTarget: Int?
    @Published private(set) var compatibilityChecked = false

    /// The last downloaded package zip, cached by content-addressed release id so a
    /// package-only asset replacement under the same firmware tag cannot reuse stale bytes.
    private var cachedSource: (releaseId: String, source: ZipPackageSource)?

    private var packageZipURL: URL?
    private let repo = "squazaryu/tumoflip"

    // Keep the screen awake and hold a background-task assertion for the duration of a
    // BLE install/recovery. The transaction can run for minutes; if the phone auto-locks
    // or the app is briefly backgrounded mid-flight, iOS tears down BLE and the half-applied
    // transaction can't be verified/rolled back over the dead link. These guards prevent that.
    #if canImport(UIKit)
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    private func beginTransactionGuards() {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = true
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "tumoflip-transaction") { [weak self] in
            self?.endTransactionGuards()
        }
        #endif
    }

    private func endTransactionGuards() {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = false
        if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
        #endif
    }

    var busy: Bool {
        if validating { return true }
        switch phase { case .checking, .downloading, .installing: return true; default: return false }
    }

    var shouldLoadManifest: Bool {
        if case .idle = phase { return manifest == nil }
        return false
    }

    func status(_ group: String) -> TumoflipInstaller.GroupStatus { groupStatus[group] ?? .empty }
    func status(file target: String) -> TumoflipInstaller.FileStatus {
        fileStatus[target] ?? .unknown
    }
    func cleanupEntries(_ group: String) -> [TumoflipManifest.CleanupEntry] {
        pendingCleanup[group] ?? []
    }

    func setManualChannelOverride(_ channel: TumoflipFirmwareChannel) {
        manualChannelOverride = channel
        firmwareRoute = TumoflipFirmwareRouter.route(identity: deviceIdentity, manualOverride: manualChannelOverride)
    }

    func clearManualChannelOverride() {
        manualChannelOverride = nil
        firmwareRoute = TumoflipFirmwareRouter.route(identity: deviceIdentity, manualOverride: nil)
    }

    /// Overall badge: any installed group out of date → Update; else any up to date → Up
    /// to date; else nothing installed.
    var overallStatus: TumoflipInstaller.GroupStatus {
        let values = groupStatus.values
        if values.contains(.updateAvailable) { return .updateAvailable }
        if values.contains(.upToDate) { return .upToDate }
        return .notInstalled
    }

    /// Compare the durable ledger to the latest manifest and, when the manifest has
    /// expected MD5s, safely adopt complete firmware-bundled groups from the device.
    func refreshStatus() async {
        guard let manifest else { return }
        transferChannel = activeChannel
        let inst = TumoflipInstaller(fs: activeFS(), source: ZipPackageSource(entries: [:]))
        do {
            let snapshot = try await inst.reconcilePackageStatus(manifest: manifest)
            groupStatus = snapshot.groups
            fileStatus = snapshot.files
            pendingCleanup = snapshot.pendingCleanup
        } catch {
            // Preserve the conservative ledger snapshot if device verification or
            // reconciliation persistence is unavailable.
            let ledger = (try? await inst.currentLedger()) ?? [:]
            groupStatus = Dictionary(uniqueKeysWithValues: TumoflipManifest.knownGroups.map {
                ($0, TumoflipInstaller.groupStatus(for: $0, manifest: manifest, ledger: ledger))
            })
            fileStatus = Dictionary(uniqueKeysWithValues: TumoflipManifest.knownGroups
                .flatMap { files($0) }
                .map { ($0.target, TumoflipInstaller.FileStatus.validationError) })
            pendingCleanup = [:]
        }
        lastVerifiedOnDevice = false
    }

    @Published private(set) var verifying = false
    /// True when `groupStatus` was last computed by hashing the actual files on the
    /// Flipper (deviceMD5), not just from the ledger snapshot.
    @Published private(set) var lastVerifiedOnDevice = false

    /// On-demand deep check: hash every recorded target on the Flipper and compare to
    /// the ledger, so the badges reflect the ACTUAL SD contents (catches files deleted
    /// or changed outside the app). Needs a connected Flipper; slower than `refreshStatus`.
    func verifyOnDevice() async {
        guard let manifest else { return }
        verifying = true
        defer { verifying = false }
        transferChannel = activeChannel
        let inst = TumoflipInstaller(fs: activeFS(), source: ZipPackageSource(entries: [:]))
        do {
            let snapshot = try await inst.reconcilePackageStatus(manifest: manifest)
            groupStatus = snapshot.groups
            fileStatus = snapshot.files
            pendingCleanup = snapshot.pendingCleanup
            lastVerifiedOnDevice = !snapshot.files.values.contains(.validationError)
        } catch {
            fileStatus = Dictionary(uniqueKeysWithValues: TumoflipManifest.knownGroups
                .flatMap { files($0) }
                .map { ($0.target, TumoflipInstaller.FileStatus.validationError) })
            pendingCleanup = [:]
            lastVerifiedOnDevice = false
        }
    }

    func count(_ group: String) -> Int { manifest?.packages[group]?.count ?? 0 }
    func bytes(_ group: String) -> Int { (manifest?.packages[group] ?? []).reduce(0) { $0 + $1.bytes } }
    func files(_ group: String) -> [TumoflipManifest.PackageFile] { manifest?.packages[group] ?? [] }

    // MARK: - Per-file selection

    func isFileSelected(_ target: String) -> Bool {
        !excludedFiles.contains(target) && blocked[target] == nil
    }

    func isFileBlocked(_ target: String) -> Bool { blocked[target] != nil }

    func setFile(_ target: String, selected: Bool) {
        if selected {
            guard blocked[target] == nil else { return }
            excludedFiles.remove(target)
        } else {
            excludedFiles.insert(target)
        }
    }

    /// How many files in a group are currently selected (not excluded).
    func selectedCount(_ group: String) -> Int {
        files(group).lazy.filter { self.isFileSelected($0.target) }.count
    }

    func selectableCount(_ group: String) -> Int {
        files(group).lazy.filter { self.blocked[$0.target] == nil }.count
    }

    /// Select/deselect every file in a group at once (the group header checkbox).
    func setGroup(_ group: String, selected: Bool) {
        let targets = files(group).map(\.target)
        if selected {
            excludedFiles.subtract(targets.filter { blocked[$0] == nil })
        } else {
            excludedFiles.formUnion(targets)
        }
    }

    /// Total selected files across all groups — drives the install bar / button.
    var selectedFileCount: Int {
        TumoflipManifest.knownGroups.reduce(0) { $0 + selectedCount($1) }
    }

    var selectedRequiresCompatibilityIdentity: Bool {
        TumoflipManifest.knownGroups.contains { group in
            files(group).contains {
                isFileSelected($0.target) && FapCompatibility.isBinary($0.target)
            }
        }
    }

    var hasFreshCompatibilityIdentity: Bool {
        compatibilityApiMajor != nil && compatibilityTarget != nil
    }

    var hasUnvalidatedBinaries: Bool {
        blocked.values.contains(FapCompatibility.unknownDeviceReason)
    }

    /// Combined entry/refresh used by the view. Sets `.checking` up front so the spinner
    /// shows instantly — even while the slower device-recover step runs (which otherwise
    /// left the phase untouched, so the screen looked frozen) — then fetches the release.
    func reload(recover: Bool) async {
        phase = .checking
        if recover { await recoverIfNeeded() }
        if case .failed = phase { return }   // recover surfaced a real install error → stop here
        await check()
    }

    /// Discover the latest tumoflip release, decode + validate its manifest, and note
    /// whether the install archive is published.
    func check() async {
        phase = .checking
        do {
            await refreshRoutingIdentity()
            let selection = try await latestRelease(
                for: firmwareRoute.channel,
                installedVersion: packageIdentityVersion
            )
            releaseTag = selection.release.tag
            let m = selection.manifest
            try m.validate()
            manifest = m
            packageZipURL = selection.release.asset("tumoflip-packages.zip")
            hasPackageZip = packageZipURL != nil
            phase = .ready
            await refreshStatus()
            // FAP/FAL API validation needs the package zip; it's triggered from the FW
            // Packages detail screen (where the user installs) rather than here, so just
            // opening the Updates overview doesn't force a package download.
        } catch {
            if UpdateTaskCancellation.isCancellation(error) {
                phase = manifest == nil ? .idle : .ready
                return
            }
            phase = .failed(friendly(error))
        }
    }

    /// Download the package zip, check device compatibility, stage + verify + atomically
    /// activate the selected groups onto the Flipper, rolling back on any failure.
    /// Set by the Stop button. The installer polls this at file/op boundaries; a stop
    /// during a FW install throws into the transactional rollback, restoring the prior
    /// working state (all-or-nothing — a firmware package set installs whole or not at
    /// all, so a partial set is never left behind).
    @Published private(set) var stopRequested = false
    private let stopToken = StopToken()
    func requestStop() { stopRequested = true; stopToken.stop() }

    func install() async {
        guard let manifest, packageZipURL != nil else { return }
        stopRequested = false; stopToken.reset()
        beginTransactionGuards()
        defer { endTransactionGuards() }
        let live = InstallActivityController()
        do {
            let requestedTargets = Set(TumoflipManifest.knownGroups.flatMap { group in
                files(group).filter { isFileSelected($0.target) }.map(\.target)
            })
            guard !requestedTargets.isEmpty else { phase = .failed("No files selected."); return }

            // Compare the connected Flipper with the manifest before touching the SD.
            let channel = activeChannel
            let fs = activeFS()
            transferChannel = channel
            // USB only changes the file-transfer path. A fresh BLE identity remains
            // mandatory so a stale manifest can never be installed after a firmware
            // update merely because its FAP API still matches.
            guard await FlipperBLE.shared.waitUntilReady(timeout: 8) else {
                phase = .failed("Connect this Flipper over BLE to validate its current firmware before installing packages via \(channel.label).")
                return
            }
            if FlipperBLE.shared.buddyMode {
                phase = .failed("Claude Buddy passthrough is holding the serial link. Turn Claude Buddy off in Settings (or exit the Buddy app on the Flipper), then retry.")
                return
            }
            try await checkCompatibility(manifest)

            let liveSelection = try await latestRelease(
                for: firmwareRoute.channel,
                installedVersion: packageIdentityVersion
            )
            guard liveSelection.release.tag == releaseTag,
                  liveSelection.manifest.releaseId == manifest.releaseId else {
                phase = .failed("The package release changed after this screen loaded. Refresh Firmware packages before installing; nothing was changed.")
                return
            }

            phase = .downloading
            let source = try await packageSource()

            // Issue #19: reject any selected FAP/FAL whose embedded `.fapmeta` is
            // incompatible with the CONNECTED firmware. Read fresh device_info now and
            // gate BEFORE ensureLoaderIdle / staging / backup / cleanup, so nothing is
            // written for a rejected binary. Non-FAP data files keep their SHA/size checks.
            let (devApi, devTarget) = await deviceApiTarget()
            compatibilityApiMajor = devApi
            compatibilityTarget = devTarget
            compatibilityChecked = true
            blocked = PackageCompatibilityGate.blocked(
                fapCandidates(source, groups: Set(TumoflipManifest.knownGroups)),
                deviceApiMajor: devApi, deviceTarget: devTarget)
            let hits = blocked.filter { requestedTargets.contains($0.key) }
            if !hits.isEmpty {
                phase = .failed(PackageCompatibilityGate.summary(hits))
                return
            }

            let effectiveExclusions = excludedFiles.union(blocked.keys)
            let groups = Set(TumoflipManifest.knownGroups.filter { group in
                files(group).contains { !effectiveExclusions.contains($0.target) }
            })
            let plan = try TumoflipInstallPlan.make(
                manifest: manifest, groups: groups, excluding: effectiveExclusions)
            guard !plan.files.isEmpty else { phase = .failed("No compatible files selected."); return }

            // A running external app may keep its own FAP open. Stop it before any
            // live path is backed up or replaced, and fail closed if Loader remains
            // locked. Core BLE/RPC stays available after the external app exits.
            if channel == .ble {
                try await ensureLoaderIdle()
            }

            phase = .installing(done: 0, total: 2 * plan.files.count, file: "Starting…")
            live.start(total: 2 * plan.files.count, title: "Installing firmware packages")
            let transferReporter = TransferActivityReporter(channel: channel)
            _ = await transferReporter.prepare()
            transferReporter.begin("firmware packages")
            defer { transferReporter.end() }
            let installer = TumoflipInstaller(fs: fs, source: source)
            let outcome = try await installer.install(
                plan, isStopRequested: { [stopToken] in stopToken.isStopped }
            ) { [weak self] done, total, file in
                Task { @MainActor in
                    self?.phase = .installing(done: done, total: total, file: file)
                    live.update(current: done, total: total, name: file)
                    transferReporter.progress(file)
                }
            }
            try await installer.refreshCompatibilityState(manifest: manifest, plan: plan)
            switch outcome {
            case .alreadyInstalled:
                phase = .done("Already installed — nothing to do.")
            case let .installed(files, legacy):
                let extra = legacy > 0 ? ", \(legacy) legacy moved aside" : ""
                phase = .done("Installed \(files) file\(files == 1 ? "" : "s")\(extra).")
            }
            live.finish(installed: 2 * plan.files.count, total: 2 * plan.files.count)
            await refreshStatus()
        } catch TumoflipInstallError.cancelled {
            // Stop requested: the transaction rolled back, so the device is exactly as
            // before — every prior version intact and fully functional.
            phase = .done("Stopped — rolled back to the previous version, nothing changed.")
            live.cancel()
            await refreshStatus()
        } catch let e as TumoflipInstallError {
            phase = .failed(installErrorText(e))
            live.cancel()
            await refreshStatus()
        } catch {
            phase = .failed(friendly(error))
            live.cancel()
            await refreshStatus()
        }
    }

    /// Roll back any transaction left half-applied by a previous crash/disconnect.
    /// Safe to call on appear; needs a connected Flipper to read its state.
    func recoverIfNeeded() async {
        beginTransactionGuards()
        defer { endTransactionGuards() }
        transferChannel = activeChannel
        let inst = TumoflipInstaller(fs: activeFS(), source: ZipPackageSource(entries: [:]))
        do { try await inst.recover() }
        catch let e as TumoflipInstallError { phase = .failed(installErrorText(e)) }
        catch { /* not connected / nothing to recover */ }
    }

    private var activeChannel: TransferChannel { TransferChannelStore.shared.activeChannel }

    private func activeFS() -> any TumoflipDeviceFS {
        if let usb = TransferChannelStore.shared.activeStore as? USBSDStorage {
            return USBTumoflipDeviceFS(storage: usb)
        }
        return FlipperDeviceFS()
    }

    private func refreshRoutingIdentity() async {
        let identity: TumoflipDeviceIdentity?
        if FlipperBLE.shared.state == .ready,
           let info = try? await FlipperSystem().deviceInfo() {
            identity = TumoflipDeviceIdentity(deviceInfo: info)
        } else {
            identity = nil
        }
        deviceIdentity = identity
        firmwareRoute = TumoflipFirmwareRouter.route(identity: identity, manualOverride: manualChannelOverride)
    }

    private var packageIdentityVersion: String? {
        deviceIdentity?.isTumoflip == true ? deviceIdentity?.firmwareVersion : nil
    }

    /// Read the connected Flipper's identity and reject incompatible packages.
    private func checkCompatibility(_ manifest: TumoflipManifest) async throws {
        let info = (try? await FlipperSystem().deviceInfo()) ?? []
        let identity = TumoflipDeviceIdentity(deviceInfo: info)
        deviceIdentity = identity
        firmwareRoute = TumoflipFirmwareRouter.route(identity: identity, manualOverride: manualChannelOverride)
        let dict = Dictionary(info, uniquingKeysWith: { a, _ in a })
        let target = dict["hardware_target"].flatMap { Int($0) }
        let apiParts = [dict["firmware_api_major"], dict["firmware_api_minor"]].compactMap { $0 }
        let api = apiParts.count == 2 ? apiParts.joined(separator: ".") : nil
        let version = dict["firmware_version"]
        let origin = dict["firmware_origin_fork"]
        try TumoflipCompat.check(deviceTarget: target, deviceAPI: api,
                                 deviceVersion: version, deviceOriginFork: origin,
                                 manifest: manifest)
    }

    // MARK: - FAP/FAL API compatibility (issue #19)

    /// Fresh device firmware API major + hardware target, read immediately before use.
    /// Both nil when the Flipper is unreachable (fail-closed at the call sites).
    private func deviceApiTarget() async -> (api: Int?, target: Int?) {
        guard FlipperBLE.shared.state == .ready else { return (nil, nil) }
        let info = (try? await FlipperSystem().deviceInfo()) ?? []
        let dict = Dictionary(info, uniquingKeysWith: { a, _ in a })
        return (dict["firmware_api_major"].flatMap(Int.init), dict["hardware_target"].flatMap(Int.init))
    }

    /// Download (or reuse) the release package zip. Cached by tag so validation and the
    /// install that follows don't fetch it twice.
    private func packageSource() async throws -> ZipPackageSource {
        guard let manifest else { throw TumoflipInstallError.sourceMissing("manifest") }
        if let cached = cachedSource, cached.releaseId == manifest.releaseId {
            return cached.source
        }
        guard let zipURL = packageZipURL else { throw TumoflipInstallError.sourceMissing("zip") }
        var request = URLRequest(
            url: zipURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 120
        )
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (tmp, _) = try await URLSession.shared.download(for: request)
        let source = try ZipPackageSource.load(zipAt: tmp)
        cachedSource = (manifest.releaseId, source)
        return source
    }

    /// Candidate FAP/FAL entries for `groups`, keyed by the RAW manifest target (so keys
    /// line up with `excludedFiles` and the file rows) and paired with a lazy byte
    /// accessor into the package zip. Data files are left for the gate to skip.
    private func fapCandidates(_ source: ZipPackageSource,
                               groups: Set<String>) -> [PackageCompatibilityGate.Candidate] {
        var out: [PackageCompatibilityGate.Candidate] = []
        for g in TumoflipManifest.knownGroups where groups.contains(g) {
            for f in files(g) {
                out.append(PackageCompatibilityGate.Candidate(
                    id: f.target, target: f.target, data: { source.entries[f.source] }))
            }
        }
        return out
    }

    /// Proactively check every FAP/FAL in the release against the connected firmware so
    /// the UI can flag incompatible files and disable install. Best-effort: no device or
    /// no zip leaves `blocked` empty (the install path still enforces fail-closed).
    func validateCompatibility() async {
        if validating { return }
        switch phase {
        case .checking, .downloading, .installing:
            return
        default:
            break
        }
        guard manifest != nil, hasPackageZip else {
            blocked = [:]
            compatibilityChecked = false
            compatibilityApiMajor = nil
            compatibilityTarget = nil
            return
        }
        validating = true
        defer { validating = false }
        let (api, target) = await deviceApiTarget()
        compatibilityApiMajor = api
        compatibilityTarget = target
        guard let source = try? await packageSource() else {
            blocked = [:]
            compatibilityChecked = false
            return
        }
        let candidates = fapCandidates(source, groups: Set(TumoflipManifest.knownGroups))
        blocked = PackageCompatibilityGate.blocked(candidates, deviceApiMajor: api, deviceTarget: target)
        compatibilityChecked = true
    }

    private func loaderLocked() async throws -> Bool {
        let responses = try await FlipperRPC.shared.command(timeout: 5) { main in
            main.content = .appLockStatusRequest(PBApp_LockStatusRequest())
        }
        for response in responses {
            if case .appLockStatusResponse(let status) = response.content {
                return status.locked
            }
        }
        throw TumoflipInstallError.activeAppCouldNotStop
    }

    private func ensureLoaderIdle() async throws {
        guard try await loaderLocked() else { return }
        do {
            _ = try await FlipperRPC.shared.command(timeout: 10) { main in
                main.content = .appExitRequest(PBApp_AppExitRequest())
            }
        } catch {
            throw TumoflipInstallError.activeAppCouldNotStop
        }
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 200_000_000)
            if try await loaderLocked() == false {
                // Loader unlock can precede the app's final file close by a short
                // interval. Give storage handles time to drain before activation.
                try await Task.sleep(nanoseconds: 750_000_000)
                return
            }
        }
        throw TumoflipInstallError.activeAppCouldNotStop
    }

    // MARK: - GitHub release discovery

    private struct Release { let tag: String; let assets: [(name: String, url: URL)]
        func asset(_ name: String) -> URL? { assets.first { $0.name == name }?.url } }

    private struct ReleaseSelection {
        let release: Release
        let manifest: TumoflipManifest
    }

    private enum ReleaseDiscoveryError: LocalizedError {
        case noMatchingPackageRelease(TumoflipFirmwareChannel, String?)

        var errorDescription: String? {
            switch self {
            case .noMatchingPackageRelease(let channel, let version):
                if let version {
                    return "No \(channel.packageLabel) release matching installed firmware \(version) was found."
                }
                return "No \(channel.packageLabel) release with tumoflip-packages.json was found."
            }
        }
    }

    private func latestRelease(
        for channel: TumoflipFirmwareChannel,
        installedVersion: String?
    ) async throws -> ReleaseSelection {
        for release in try await releases() {
            guard let manifestURL = release.asset("tumoflip-packages.json") else { continue }
            guard let manifest = try? await manifest(from: manifestURL) else { continue }
            if TumoflipPackageReleaseMatcher.matches(
                manifestVersion: manifest.firmware.version,
                channel: channel,
                installedVersion: installedVersion
            ) {
                return ReleaseSelection(release: release, manifest: manifest)
            }
        }
        throw ReleaseDiscoveryError.noMatchingPackageRelease(channel, installedVersion)
    }

    private func releases() async throws -> [Release] {
        var components = URLComponents(string: "https://api.github.com/repos/\(repo)/releases")!
        components.queryItems = [
            URLQueryItem(name: "per_page", value: "50"),
            URLQueryItem(name: "_tumoflip_refresh", value: String(Int(Date().timeIntervalSince1970))),
        ]
        var req = URLRequest(
            url: components.url!,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 30
        )
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw URLError(.badServerResponse)
        }
        return array.compactMap { obj in
            guard let tag = obj["tag_name"] as? String,
                  let assetsJSON = obj["assets"] as? [[String: Any]] else { return nil }
            let assets: [(String, URL)] = assetsJSON.compactMap {
                guard let n = $0["name"] as? String,
                      let u = ($0["browser_download_url"] as? String).flatMap(URL.init) else { return nil }
                return (n, u)
            }
            return Release(tag: tag, assets: assets)
        }
    }

    private func manifest(from url: URL) async throws -> TumoflipManifest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 30
        )
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try TumoflipManifest.decode(data)
    }

    private func installErrorText(_ e: TumoflipInstallError) -> String {
        switch e {
        case .sourceMissing(let s): return "Missing in archive: \(s) — rolled back."
        case .hashMismatch(let s): return "Hash mismatch: \(s) — rolled back."
        case .deviceVerifyFailed(let t): return "On-device verify failed: \(t) — rolled back."
        case .incompatible(let m): return "Incompatible: \(m). Nothing was changed."
        case .rollbackIncomplete(let t):
            return "Install failed AND rollback could not restore \(t.count) file(s): \(t.joined(separator: ", ")). Re-open to retry recovery."
        case .statePersistenceFailed(let path):
            return "Could not safely persist transaction state at \(path). Nothing else will be changed."
        case .activeAppCouldNotStop:
            return "Close the running Flipper app and retry. No package files were changed."
        case .cancelled:
            // Normally handled as a friendly "Stopped" in install()'s catch; this is the
            // fallback wording if it ever reaches here.
            return "Stopped — rolled back to the previous version, nothing changed."
        }
    }
    private func friendly(_ error: Error) -> String {
        if (error as? URLError)?.code == .some(.notConnectedToInternet) { return "No internet connection." }
        if case FlipperRPCError.timeout = error {
            return "The Flipper stopped responding over Bluetooth during the install. "
                + "Reboot the Flipper, reconnect, then try again — the transaction was rolled "
                + "back, so your files are safe. (A wired install is more reliable for large sets.)"
        }
        return error.localizedDescription
    }
}
