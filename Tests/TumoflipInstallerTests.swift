import XCTest
@testable import UnleashedCompanion

/// Orchestrator tests for the atomic tumoflip installer (issue #8): write-ahead
/// staging, abort-with-no-partial-activation, crash recovery at each interruption
/// point, rollback failure surfacing, reversible cleanup, group-aware idempotency,
/// and device compatibility. Hardware-independent — a fake device FS + package source
/// stand in for the Flipper.
final class TumoflipInstallerTests: XCTestCase {

    // MARK: - Fakes

    private final class FakeFS: TumoflipDeviceFS, @unchecked Sendable {
        enum Err: Error { case injected, notFound }
        var files: [String: Data] = [:]
        var dirs = Set<String>()
        var writeCount = 0
        var corruptWrites = false
        var failWrite: ((String) -> Bool)?
        var failMove: ((String, String) -> Bool)?
        var failMoveAfterCopy: ((String, String) -> Bool)?
        var failMoveAfterRemove: ((String, String) -> Bool)?
        var checkedMD5FailuresRemaining = 0

        func write(_ data: Data, to path: String) async throws {
            if failWrite?(path) == true { throw Err.injected }
            writeCount += 1
            let isState = path == TumoflipInstaller.stateSlotA || path == TumoflipInstaller.stateSlotB
            files[path] = corruptWrites && !isState ? (data + Data([0xFF])) : data
        }
        func read(_ path: String) async -> Data? { files[path] }
        func deviceMD5(_ path: String) async -> String? { files[path].map { TumoflipHash.md5($0) } }
        func checkedDeviceMD5(_ path: String) async throws -> String? {
            if checkedMD5FailuresRemaining > 0 {
                checkedMD5FailuresRemaining -= 1
                throw Err.injected
            }
            return await deviceMD5(path)
        }
        func move(_ from: String, to: String) async throws {
            if failMove?(from, to) == true { throw Err.injected }
            guard let d = files[from] else { throw Err.notFound }
            files[to] = d
            if failMoveAfterCopy?(from, to) == true { throw Err.injected }
            files[from] = nil
            if failMoveAfterRemove?(from, to) == true { throw Err.injected }
        }
        func delete(_ path: String) async throws { files[path] = nil }
        func deleteTree(_ path: String) async throws {
            files = files.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
            dirs = dirs.filter { $0 != path && !$0.hasPrefix(path + "/") }
        }
        func makeDirectory(_ path: String) async throws { dirs.insert(path) }
        func exists(_ path: String) async -> Bool { files[path] != nil }
        func readState() async -> TumoflipState? {
            [TumoflipInstaller.stateSlotA, TumoflipInstaller.stateSlotB]
                .compactMap { files[$0].flatMap(TumoflipInstaller.decodeStateSlot) }
                .max { $0.generation < $1.generation }
        }
        func seedState(_ state: TumoflipState) {
            files[TumoflipInstaller.stateSlotA] = try! TumoflipInstaller.encodeStateSlot(state)
        }
    }

    private struct FakeSource: TumoflipPackageSource {
        var data: [String: Data]
        func bytes(for source: String) async throws -> Data {
            guard let d = data[source] else { throw TumoflipInstallError.sourceMissing(source) }
            return d
        }
    }

    func testCompatibilityStateReflectsCommittedManifestAndPlan() async throws {
        let fs = FakeFS()
        let bytes = Data("new-app".utf8)
        let manifest = TumoflipManifest(
            schema: 2,
            releaseId: String(repeating: "a", count: 64),
            firmware: .init(
                api: "88.0", name: "tumoflip", version: "t-dev-089-037-058",
                target: 7, radioAddress: nil),
            artifacts: [:],
            packages: [
                "base": [.init(
                    bytes: bytes.count, sha256: TumoflipHash.sha256(bytes),
                    source: "apps/new.fap", target: "/ext/apps/Tools/new.fap")],
                "arf": [], "module_one": [], "protocol_packs": [],
            ],
            cleanup: [],
            safety: nil
        )
        let plan = try TumoflipInstallPlan.make(manifest: manifest, groups: ["base"])
        let installer = TumoflipInstaller(fs: fs, source: FakeSource(data: [:]))

        try await installer.refreshCompatibilityState(manifest: manifest, plan: plan)

        let compact = try XCTUnwrap(fs.files["/ext/.tumoflip/package-state.txt"])
        let compactText = try XCTUnwrap(String(data: compact, encoding: .utf8))
        XCTAssertTrue(compactText.contains("Firmware: t-dev-089-037-058"))
        XCTAssertTrue(compactText.contains("InstalledFiles: 1"))
        XCTAssertTrue(compactText.contains("ReleaseId: \(manifest.releaseId)"))

        let compatibility = try XCTUnwrap(fs.files["/ext/.tumoflip/install-state.json"])
        let decoded = try JSONSerialization.jsonObject(with: compatibility) as? [String: Any]
        XCTAssertEqual(decoded?["release_id"] as? String, manifest.releaseId)
        XCTAssertEqual(decoded?["groups"] as? [String], ["base"])
        XCTAssertEqual((decoded?["files"] as? [[String: Any]])?.count, 1)
    }

    private let rid = String(repeating: "c", count: 64)

    private func file(_ source: String, _ target: String, _ bytes: Data) -> TumoflipManifest.PackageFile {
        .init(bytes: bytes.count, sha256: TumoflipHash.sha256(bytes), source: source, target: target)
    }
    private func plan(_ files: [TumoflipManifest.PackageFile],
                      cleanup: [TumoflipManifest.CleanupEntry] = [],
                      groups: [String] = ["base"]) -> TumoflipInstallPlan {
        .init(releaseId: rid, groups: groups, files: files, cleanup: cleanup)
    }

    // MARK: - Success

    func testCleanInstall() async throws {
        let b1 = Data("one".utf8), b2 = Data("two".utf8)
        let p = plan([file("a", "/ext/apps/a.fap", b1), file("b", "/ext/apps/b.fap", b2)])
        let fs = FakeFS()
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: ["a": b1, "b": b2]))
        let outcome = try await inst.install(p)
        XCTAssertEqual(outcome, .installed(files: 2, legacyMovedAside: 0))
        XCTAssertEqual(fs.files["/ext/apps/a.fap"], b1)
        XCTAssertEqual(fs.files["/ext/apps/b.fap"], b2)
        let st = await fs.readState()
        XCTAssertNil(st?.txn, "transaction cleared after commit")
        XCTAssertEqual(st?.ledger["/ext/apps/a.fap"]?.sha256, TumoflipHash.sha256(b1))
        XCTAssertFalse(fs.files.keys.contains { $0.contains("/.tumoflip/staging/") })
        XCTAssertFalse(fs.files.keys.contains { $0.contains("/.tumoflip/rollback/") })
    }

    func testIdenticalLiveFileIsRecordedWithoutMove() async throws {
        let bytes = Data("already-current".utf8)
        let target = "/ext/apps/Bluetooth/flipper_companion.fap"
        let p = plan([file("companion", target, bytes)])
        let fs = FakeFS()
        fs.files[target] = bytes
        fs.failMove = { _, _ in true }

        let inst = TumoflipInstaller(
            fs: fs, source: FakeSource(data: ["companion": bytes]))
        let outcome = try await inst.install(p)

        XCTAssertEqual(outcome, .installed(files: 1, legacyMovedAside: 0))
        XCTAssertEqual(fs.files[target], bytes)
        let state = await fs.readState()
        XCTAssertNil(state?.txn)
        XCTAssertEqual(state?.ledger[target]?.md5, TumoflipHash.md5(bytes))
    }

    // MARK: - Abort with no partial activation

    func testHashMismatchActivatesNothing() async throws {
        let good = Data("good".utf8)
        let bad = TumoflipManifest.PackageFile(bytes: 4, sha256: String(repeating: "0", count: 64),
                                               source: "b", target: "/ext/apps/b.fap")
        let p = plan([file("a", "/ext/apps/a.fap", good), bad])
        let fs = FakeFS()
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: ["a": good, "b": Data("bad".utf8)]))
        await assertThrows({ try await inst.install(p) }, .hashMismatch("b"))
        XCTAssertNil(fs.files["/ext/apps/a.fap"])
        XCTAssertNil(fs.files["/ext/apps/b.fap"])
        let finalState = await fs.readState(); XCTAssertNil(finalState?.txn)
    }

    func testDeviceVerifyFailureAborts() async throws {
        let b = Data("x".utf8)
        let p = plan([file("a", "/ext/apps/a.fap", b)])
        let fs = FakeFS(); fs.corruptWrites = true
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: ["a": b]))
        await assertThrows({ try await inst.install(p) }, .deviceVerifyFailed("/ext/apps/a.fap"))
        XCTAssertNil(fs.files["/ext/apps/a.fap"])
    }

    // MARK: - In-process rollback

    func testInterruptedActivationRollsBack() async throws {
        let old1 = Data("OLD1".utf8), old2 = Data("OLD2".utf8)
        let new1 = Data("new1".utf8), new2 = Data("new2".utf8)
        let t1 = "/ext/apps/a.fap", t2 = "/ext/apps/b.fap"
        let p = plan([file("a", t1, new1), file("b", t2, new2)])
        let fs = FakeFS()
        fs.files[t1] = old1; fs.files[t2] = old2
        // Fail ONLY the activation (staged -> target) move for the 2nd file, not the
        // later restore (backup -> target) move.
        fs.failMove = { from, to in to == t2 && from.contains("/staging/") }
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: ["a": new1, "b": new2]))
        do { _ = try await inst.install(p); XCTFail("expected failure") } catch {}
        XCTAssertEqual(fs.files[t1], old1, "t1 restored")
        XCTAssertEqual(fs.files[t2], old2, "t2 restored")
        let finalState = await fs.readState(); XCTAssertNil(finalState?.txn)
    }

    // MARK: - Stop (user pressed Stop → rollback, the app stays fully functional)

    /// Stop requested before any staging: nothing is written or activated, and the
    /// app you stopped on keeps its previous, working version.
    func testStopBeforeStagingLeavesDeviceUnchanged() async throws {
        let old = Data("OLD".utf8), new = Data("new".utf8)
        let t = "/ext/apps/a.fap"
        let p = plan([file("a", t, new)])
        let fs = FakeFS()
        fs.files[t] = old
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: ["a": new]))
        await assertThrows({ try await inst.install(p, isStopRequested: { true }) }, .cancelled)
        XCTAssertEqual(fs.files[t], old, "prior working version untouched")
        XCTAssertFalse(fs.files.keys.contains { $0.contains("/staging/") }, "nothing staged")
        let st = await fs.readState(); XCTAssertNil(st?.txn, "transaction rolled back / cleared")
    }

    /// Stop during staging (after the first file is staged, before the second):
    /// staging touches no live path, so BOTH live apps keep their previous versions.
    func testStopDuringStagingChangesNoLiveFile() async throws {
        let old1 = Data("OLD1".utf8), old2 = Data("OLD2".utf8)
        let new1 = Data("new1".utf8), new2 = Data("new2".utf8)
        let t1 = "/ext/apps/a.fap", t2 = "/ext/apps/b.fap"
        let p = plan([file("a", t1, new1), file("b", t2, new2)])
        let fs = FakeFS()
        fs.files[t1] = old1; fs.files[t2] = old2
        // Trip the stop as soon as the first staging file exists — the boundary check
        // at the top of the 2nd staging iteration then throws.
        let stop: @Sendable () -> Bool = { fs.files.keys.contains { $0.contains("/staging/") } }
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: ["a": new1, "b": new2]))
        await assertThrows({ try await inst.install(p, isStopRequested: stop) }, .cancelled)
        XCTAssertEqual(fs.files[t1], old1, "no live path touched during staging")
        XCTAssertEqual(fs.files[t2], old2)
        let st = await fs.readState(); XCTAssertNil(st?.txn)
    }

    /// Stop DURING activation, after the first file has been swapped live: the
    /// transactional rollback must restore the already-activated file to its prior
    /// version, so the app you stopped on remains fully functional.
    func testStopDuringActivationRestoresPriorVersion() async throws {
        let old1 = Data("OLD1".utf8), old2 = Data("OLD2".utf8)
        let new1 = Data("new1".utf8), new2 = Data("new2".utf8)
        let t1 = "/ext/apps/a.fap", t2 = "/ext/apps/b.fap"
        let p = plan([file("a", t1, new1), file("b", t2, new2)])
        let fs = FakeFS()
        fs.files[t1] = old1; fs.files[t2] = old2
        // Stop once t1 is live-activated (== new1). The boundary check at the top of the
        // 2nd activation iteration then throws → rollback restores t1 to old1.
        let stop: @Sendable () -> Bool = { fs.files[t1] == new1 }
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: ["a": new1, "b": new2]))
        await assertThrows({ try await inst.install(p, isStopRequested: stop) }, .cancelled)
        XCTAssertEqual(fs.files[t1], old1, "activated file rolled back to its prior working version")
        XCTAssertEqual(fs.files[t2], old2, "not-yet-activated file untouched")
        let st = await fs.readState(); XCTAssertNil(st?.txn)
    }

    func testRollbackDoesNotDeleteLaterStagedTargets() async throws {
        let oldBase = Data("old-base".utf8), oldARF = Data("old-arf".utf8)
        let newBase = Data("new-base".utf8), newARF = Data("new-arf".utf8)
        let base = "/ext/apps/Bluetooth/flipper_companion.fap"
        let arf = "/ext/apps/ARF Tools/arf_keeloq.fap"
        let p = plan([file("base", base, newBase), file("arf", arf, newARF)])
        let fs = FakeFS()
        fs.files[base] = oldBase
        fs.files[arf] = oldARF
        fs.failMove = { from, to in from.contains("/staging/") && to == base }

        let inst = TumoflipInstaller(
            fs: fs, source: FakeSource(data: ["base": newBase, "arf": newARF]))
        do { _ = try await inst.install(p); XCTFail("expected activation failure") } catch {}

        XCTAssertEqual(fs.files[base], oldBase, "failed Base activation restored")
        XCTAssertEqual(fs.files[arf], oldARF, "untouched staged ARF target must remain live")
        let finalState = await fs.readState()
        XCTAssertNil(finalState?.txn)
    }

    func testRollbackFailureIsSurfacedNotSwallowed() async throws {
        let old1 = Data("OLD1".utf8), new1 = Data("new1".utf8), new2 = Data("new2".utf8)
        let t1 = "/ext/apps/a.fap", t2 = "/ext/apps/b.fap"
        let p = plan([file("a", t1, new1), file("b", t2, new2)])
        let fs = FakeFS()
        fs.files[t1] = old1                                  // only t1 pre-exists
        // Fail activating t2 (triggers rollback) AND fail restoring t1 from its backup.
        fs.failMove = { from, to in to == t2 || (to == t1 && from.contains("rollback")) }
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: ["a": new1, "b": new2]))
        do { _ = try await inst.install(p); XCTFail("expected rollbackIncomplete") }
        catch {
            guard case .rollbackIncomplete(let t)? = error as? TumoflipInstallError else {
                return XCTFail("got \(error)")
            }
            XCTAssertTrue(t.contains(t1))
        }
        // Not claimed rolled back — the txn stays recoverable.
        let st = await fs.readState()
        XCTAssertEqual(st?.txn?.phase, .activating)
    }

    // MARK: - Crash recovery (out-of-process), considering real fs presence

    /// Build a persisted state representing a crash partway through activation, plus the
    /// matching filesystem snapshot, then return a fresh installer over the same FS.
    private func crashSnapshot() -> (FakeFS, TumoflipInstaller) {
        let fs = FakeFS()
        let new0 = Data("new0".utf8), old0 = Data("old0".utf8)
        let new1 = Data("new1".utf8), old1 = Data("old1".utf8)
        let op0 = TumoflipJournal.FileOp(target: "/ext/a", stage: "/ext/.tumoflip/staging/x/a",
                                         backup: "/ext/.tumoflip/rollback/x/a",
                                         sha256: TumoflipHash.sha256(new0), md5: TumoflipHash.md5(new0),
                                         originalMD5: TumoflipHash.md5(old0), hadOriginal: true,
                                         state: .activated)
        let op1 = TumoflipJournal.FileOp(target: "/ext/b", stage: "/ext/.tumoflip/staging/x/b",
                                         backup: "/ext/.tumoflip/rollback/x/b",
                                         sha256: TumoflipHash.sha256(new1), md5: TumoflipHash.md5(new1),
                                         originalMD5: TumoflipHash.md5(old1), hadOriginal: true,
                                         state: .backedUp)
        // op0 fully activated; op1 backed up but staged file not yet renamed in.
        fs.files[op0.target] = new0; fs.files[op0.backup] = old0
        fs.files[op1.backup] = old1; fs.files[op1.stage] = new1
        let j = TumoflipJournal(releaseId: "r", fingerprint: String(repeating: "f", count: 64),
                                groups: ["base"], phase: .activating, ops: [op0, op1], cleanups: [])
        var state = TumoflipState(); state.txn = j
        fs.seedState(state)
        return (fs, TumoflipInstaller(fs: fs, source: FakeSource(data: [:])))
    }

    func testRecoverInterruptedActivationRestoresAll() async throws {
        let (fs, inst) = crashSnapshot()
        try await inst.recover()
        XCTAssertEqual(fs.files["/ext/a"], Data("old0".utf8), "op0 original restored")
        XCTAssertEqual(fs.files["/ext/b"], Data("old1".utf8), "op1 original restored")
        let finalState = await fs.readState(); XCTAssertNil(finalState?.txn)
    }

    func testRecoverRestoresMovedAsideLegacy() async throws {
        let fs = FakeFS()
        let legacyBytes = Data("legacy".utf8)
        let op0 = TumoflipJournal.FileOp(target: "/ext/a", stage: "/ext/.tumoflip/staging/x/a",
                                         backup: "/ext/.tumoflip/rollback/x/a",
                                         sha256: TumoflipHash.sha256(Data("new".utf8)),
                                         md5: TumoflipHash.md5(Data("new".utf8)),
                                         originalMD5: TumoflipHash.md5(Data("orig".utf8)),
                                         hadOriginal: true, state: .backedUp)
        fs.files[op0.backup] = Data("orig".utf8)            // original backed up, target absent
        let cl = TumoflipJournal.CleanupOp(legacy: "/ext/Old.fap",
                                           backup: "/ext/.tumoflip/rollback/x/cleanup__Old.fap",
                                           md5: TumoflipHash.md5(legacyBytes), state: .movedAside)
        fs.files[cl.backup] = legacyBytes                   // legacy already moved aside
        let j = TumoflipJournal(releaseId: "r", fingerprint: String(repeating: "f", count: 64),
                                groups: ["arf"], phase: .activating, ops: [op0], cleanups: [cl])
        var state = TumoflipState(); state.txn = j
        fs.seedState(state)
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: [:]))

        try await inst.recover()
        XCTAssertEqual(fs.files["/ext/a"], Data("orig".utf8), "op original restored")
        XCTAssertEqual(fs.files["/ext/Old.fap"], legacyBytes, "moved-aside legacy restored")
        let finalState = await fs.readState(); XCTAssertNil(finalState?.txn)
    }

    func testAllCorruptedStateSlotsFailClosed() async throws {
        let b = Data("z".utf8)
        let p = plan([file("a", "/ext/apps/a.fap", b)])
        let fs = FakeFS()
        fs.files[TumoflipInstaller.stateSlotA] = Data("{ not valid json".utf8)
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: ["a": b]))
        await assertThrows(
            { try await inst.install(p) },
            .statePersistenceFailed("both state slots are invalid"))
        XCTAssertNil(fs.files["/ext/apps/a.fap"])
    }

    // MARK: - Idempotency & incremental groups

    func testRepeatInstallIsNoOp() async throws {
        let b = Data("z".utf8)
        let p = plan([file("a", "/ext/apps/a.fap", b)])
        let fs = FakeFS()
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: ["a": b]))
        _ = try await inst.install(p)
        let countAfterFirst = fs.writeCount
        let outcome = try await inst.install(p)
        XCTAssertEqual(outcome, .alreadyInstalled)
        XCTAssertEqual(fs.writeCount, countAfterFirst, "no-op must not write")
    }

    func testRepeatInstallExecutesPendingCleanup() async throws {
        let bytes = Data("canonical".utf8)
        let canonical = "/ext/apps/Module One/Diagnostics/cockpit.fap"
        let legacy = "/ext/apps/Module One/Diagnostics/module_one_cockpit.fap"
        let p = plan(
            [file("cockpit", canonical, bytes)],
            cleanup: [.init(canonical: canonical, legacy: legacy)],
            groups: ["module_one"])
        let fs = FakeFS()
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: ["cockpit": bytes]))

        _ = try await inst.install(p)
        fs.files[legacy] = Data("legacy".utf8)

        let outcome = try await inst.install(p)

        XCTAssertEqual(outcome, .installed(files: 1, legacyMovedAside: 1))
        XCTAssertEqual(fs.files[canonical], bytes)
        XCTAssertNil(fs.files[legacy], "pending cleanup must prevent the already-installed fast path")
    }

    func testIncrementalGroupInstallSameRelease() async throws {
        let base = Data("base".utf8), arf = Data("arf".utf8)
        let fs = FakeFS()
        let source = FakeSource(data: ["base": base, "arf": arf])
        let inst = TumoflipInstaller(fs: fs, source: source)
        // Install Base alone.
        _ = try await inst.install(plan([file("base", "/ext/apps/base.fap", base)], groups: ["base"]))
        XCTAssertEqual(fs.files["/ext/apps/base.fap"], base)
        // Now install ARF for the SAME release — must NOT be treated as already done.
        let outcome = try await inst.install(plan([file("arf", "/ext/apps/arf.fap", arf)], groups: ["arf"]))
        XCTAssertEqual(outcome, .installed(files: 1, legacyMovedAside: 0))
        XCTAssertEqual(fs.files["/ext/apps/arf.fap"], arf)
        XCTAssertEqual(fs.files["/ext/apps/base.fap"], base, "Base still present after ARF")
    }

    // MARK: - Reversible cleanup (forward path)

    func testCleanupMovesLegacyAside() async throws {
        let b = Data("c".utf8)
        let canonical = "/ext/apps/ARF Tools/arf.fap", legacy = "/ext/apps/ARF Tools/ARF Old.fap"
        let p = plan([file("a", canonical, b)],
                     cleanup: [.init(canonical: canonical, legacy: legacy)], groups: ["arf"])
        let fs = FakeFS()
        fs.files[legacy] = Data("legacy".utf8)
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: ["a": b]))
        let outcome = try await inst.install(p)
        XCTAssertEqual(outcome, .installed(files: 1, legacyMovedAside: 1))
        XCTAssertEqual(fs.files[canonical], b)
        XCTAssertNil(fs.files[legacy], "legacy moved out of its live path")
    }

    func testMissingLegacyCleanupIsIgnored() async throws {
        let bytes = Data("canonical".utf8)
        let canonical = "/ext/apps/ARF Tools/arf_car_emulate.fap"
        let missingLegacy = "/ext/apps/ARF Tools/ARF Car Emulate.fap"
        let p = plan(
            [file("car", canonical, bytes)],
            cleanup: [.init(canonical: canonical, legacy: missingLegacy)],
            groups: ["arf"])
        let fs = FakeFS()
        fs.files[canonical] = bytes
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: ["car": bytes]))

        let outcome = try await inst.install(p)

        XCTAssertEqual(outcome, .installed(files: 1, legacyMovedAside: 0))
        XCTAssertEqual(fs.files[canonical], bytes)
        XCTAssertNil(fs.files[missingLegacy])
    }

    // MARK: - Flipper copy+remove move semantics

    func testActivationErrorAfterCopyIsReconciled() async throws {
        let bytes = Data("new".utf8)
        let target = "/ext/apps/a.fap"
        let p = plan([file("a", target, bytes)])
        let fs = FakeFS()
        fs.failMoveAfterCopy = { from, to in from.contains("/staging/") && to == target }

        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: ["a": bytes]))
        let outcome = try await inst.install(p)

        XCTAssertEqual(outcome, .installed(files: 1, legacyMovedAside: 0))
        XCTAssertEqual(fs.files[target], bytes)
        XCTAssertFalse(fs.files.keys.contains { $0.contains("/staging/") && $0.hasSuffix("a.fap") })
    }

    func testBackupErrorAfterCopyIsReconciled() async throws {
        let old = Data("old".utf8), new = Data("new".utf8)
        let target = "/ext/apps/a.fap"
        let p = plan([file("a", target, new)])
        let fs = FakeFS()
        fs.files[target] = old
        fs.failMoveAfterCopy = { from, to in from == target && to.contains("/rollback/") }

        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: ["a": new]))
        let outcome = try await inst.install(p)

        XCTAssertEqual(outcome, .installed(files: 1, legacyMovedAside: 0))
        XCTAssertEqual(fs.files[target], new)
    }

    func testRecoverRemovesPartialActivationCopyAndRestoresOriginal() async throws {
        let old = Data("old".utf8), new = Data("new".utf8)
        let target = "/ext/apps/a.fap"
        let stage = "/ext/.tumoflip/staging/x/a.fap"
        let backup = "/ext/.tumoflip/rollback/x/a.fap"
        let op = TumoflipJournal.FileOp(
            target: target,
            stage: stage,
            backup: backup,
            sha256: TumoflipHash.sha256(new),
            md5: TumoflipHash.md5(new),
            originalMD5: TumoflipHash.md5(old),
            hadOriginal: true,
            state: .activationPlanned)
        let journal = TumoflipJournal(
            releaseId: rid,
            fingerprint: String(repeating: "f", count: 64),
            groups: ["base"],
            phase: .activating,
            ops: [op],
            cleanups: [])
        var state = TumoflipState()
        state.txn = journal
        let fs = FakeFS()
        fs.files[target] = Data("pa".utf8) // torn destination copy
        fs.files[stage] = new
        fs.files[backup] = old
        fs.seedState(state)

        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: [:]))
        try await inst.recover()

        XCTAssertEqual(fs.files[target], old)
        let recoveredState = await fs.readState()
        XCTAssertNil(recoveredState?.txn)
    }

    func testCorruptNewestStateSlotFallsBackToPreviousGeneration() async {
        var previous = TumoflipState(generation: 7)
        previous.ledger["/ext/apps/a.fap"] = .init(
            sha256: String(repeating: "a", count: 64), md5: "old", releaseId: rid)
        let fs = FakeFS()
        fs.files[TumoflipInstaller.stateSlotB] = try! TumoflipInstaller.encodeStateSlot(previous)
        fs.files[TumoflipInstaller.stateSlotA] = Data("partial-json".utf8)

        let loaded = await fs.readState()
        XCTAssertEqual(loaded, previous)
    }

    // MARK: - Device compatibility

    func testCompatOK() throws {
        let m = makeManifest(target: 7, api: "87.14")
        XCTAssertNoThrow(try TumoflipCompat.check(deviceTarget: 7, deviceAPI: "87.14",
                                                  deviceVersion: "v", deviceOriginFork: "tumoflip", manifest: m))
    }

    func testCompatUnknownDeviceIdentityFailsClosed() {
        let m = makeManifest(target: 7, api: "87.14")
        XCTAssertThrowsError(try TumoflipCompat.check(deviceTarget: nil, deviceAPI: nil,
                                                      deviceVersion: nil, manifest: m)) {
            guard case .incompatible? = $0 as? TumoflipInstallError else { return XCTFail("\($0)") }
        }
    }

    func testCompatTargetMismatch() {
        let m = makeManifest(target: 7, api: "87.14")
        XCTAssertThrowsError(try TumoflipCompat.check(deviceTarget: 5, deviceAPI: "87.14",
                                                      deviceVersion: "v", deviceOriginFork: "tumoflip", manifest: m)) {
            guard case .incompatible? = $0 as? TumoflipInstallError else { return XCTFail("\($0)") }
        }
    }

    func testCompatAPIMismatch() {
        let m = makeManifest(target: 7, api: "87.14")
        XCTAssertThrowsError(try TumoflipCompat.check(deviceTarget: 7, deviceAPI: "87.13",
                                                      deviceVersion: "v", deviceOriginFork: "tumoflip", manifest: m)) {
            guard case .incompatible? = $0 as? TumoflipInstallError else { return XCTFail("\($0)") }
        }
    }

    func testCompatFirmwareVersionMismatch() {
        let m = makeManifest(target: 7, api: "87.14")
        XCTAssertThrowsError(try TumoflipCompat.check(deviceTarget: 7, deviceAPI: "87.14",
                                                      deviceVersion: "old", deviceOriginFork: "tumoflip", manifest: m)) {
            guard case .incompatible? = $0 as? TumoflipInstallError else { return XCTFail("\($0)") }
        }
    }

    func testCompatOriginMismatch() {
        let m = makeManifest(target: 7, api: "87.14")
        XCTAssertThrowsError(try TumoflipCompat.check(deviceTarget: 7, deviceAPI: "87.14",
                                                      deviceVersion: "v", deviceOriginFork: "unleashed", manifest: m)) {
            guard case .incompatible? = $0 as? TumoflipInstallError else { return XCTFail("\($0)") }
        }
    }

    private func makeManifest(target: Int, api: String) -> TumoflipManifest {
        TumoflipManifest(schema: 2, releaseId: rid,
                         firmware: .init(api: api, name: "tumoflip", version: "v", target: target, radioAddress: nil),
                         artifacts: [:], packages: [:], cleanup: [], safety: nil)
    }

    // MARK: - Device-backed verification ("Verify on device", #9)

    private func baseManifest(_ files: [TumoflipManifest.PackageFile]) -> TumoflipManifest {
        TumoflipManifest(schema: 2, releaseId: rid,
                         firmware: .init(api: "87.14", name: "tumoflip", version: "v", target: 7, radioAddress: nil),
                         artifacts: [:],
                         packages: ["base": files, "arf": [], "module_one": [], "protocol_packs": []],
                         cleanup: [], safety: nil)
    }
    private func manifest(_ files: [TumoflipManifest.PackageFile],
                          cleanup: [TumoflipManifest.CleanupEntry] = []) -> TumoflipManifest {
        TumoflipManifest(schema: 2, releaseId: rid,
                         firmware: .init(api: "87.14", name: "tumoflip", version: "v", target: 7, radioAddress: nil),
                         artifacts: [:],
                         packages: ["base": files, "arf": [], "module_one": [], "protocol_packs": []],
                         cleanup: cleanup, safety: nil)
    }
    private func bundledFile(_ source: String, _ target: String,
                             _ bytes: Data) -> TumoflipManifest.PackageFile {
        .init(bytes: bytes.count, sha256: TumoflipHash.sha256(bytes),
              md5: TumoflipHash.md5(bytes), source: source, target: target)
    }
    private func entry(_ sha: String, _ bytes: Data) -> TumoflipState.LedgerEntry {
        .init(sha256: sha, md5: TumoflipHash.md5(bytes), releaseId: rid)
    }

    func testVerifyUpToDateWhenPresentAndIntact() async {
        let bytes = Data("content".utf8), target = "/ext/apps/a.fap"
        let f = file("a", target, bytes)
        let fs = FakeFS(); fs.files[target] = bytes                       // physically present + intact
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: [:]))
        let status = await inst.verifyGroupOnDevice("base", manifest: baseManifest([f]),
                                                    ledger: [target: entry(f.sha256, bytes)])
        XCTAssertEqual(status, .upToDate)
    }

    func testVerifyFlagsMissingFile() async {
        let bytes = Data("content".utf8), target = "/ext/apps/a.fap"
        let f = file("a", target, bytes)
        let fs = FakeFS()                                                 // target NOT on device
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: [:]))
        let status = await inst.verifyGroupOnDevice("base", manifest: baseManifest([f]),
                                                    ledger: [target: entry(f.sha256, bytes)])
        XCTAssertEqual(status, .updateAvailable)
    }

    func testVerifyFlagsChangedFile() async {
        let bytes = Data("content".utf8), target = "/ext/apps/a.fap"
        let f = file("a", target, bytes)
        let fs = FakeFS(); fs.files[target] = Data("CHANGED".utf8)        // present but different bytes
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: [:]))
        let status = await inst.verifyGroupOnDevice("base", manifest: baseManifest([f]),
                                                    ledger: [target: entry(f.sha256, bytes)])
        XCTAssertEqual(status, .updateAvailable)
    }

    func testVerifyNotInstalledForFileNotInLedger() async {
        // A file physically present but installed OUTSIDE the app (no ledger entry):
        // can't confirm without the expected hash, so it's reported as not installed.
        let bytes = Data("content".utf8), target = "/ext/apps/a.fap"
        let f = file("a", target, bytes)
        let fs = FakeFS(); fs.files[target] = bytes
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: [:]))
        let status = await inst.verifyGroupOnDevice("base", manifest: baseManifest([f]), ledger: [:])
        XCTAssertEqual(status, .notInstalled)
    }

    // MARK: - Firmware-resource adoption (#39)

    func testReconcileAdoptsCompleteFirmwareBundledGroup() async throws {
        let a = Data("firmware-a".utf8), b = Data("firmware-b".utf8)
        let files = [bundledFile("a", "/ext/apps/a.fap", a),
                     bundledFile("b", "/ext/apps/b.fap", b)]
        let fs = FakeFS()
        fs.files[files[0].target] = a
        fs.files[files[1].target] = b
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: [:]))

        let statuses = try await inst.reconcileStatus(manifest: manifest(files))

        XCTAssertEqual(statuses["base"], .upToDate)
        let loadedState = await fs.readState()
        let state = try XCTUnwrap(loadedState)
        XCTAssertEqual(state.ledger[files[0].target]?.md5, files[0].md5)
        XCTAssertEqual(state.ledger[files[1].target]?.sha256, files[1].sha256)
        XCTAssertNotNil(fs.files["/ext/.tumoflip/install-state.json"])
        XCTAssertNotNil(fs.files["/ext/.tumoflip/package-state.txt"])
    }

    func testDetailedReconcileReportsEveryCompleteMD5FileStatus() async throws {
        let current = Data("current".utf8)
        let changed = Data("expected-changed".utf8)
        let missing = Data("expected-missing".utf8)
        let files = [
            bundledFile("current", "/ext/apps/current.fap", current),
            bundledFile("changed", "/ext/apps/changed.fap", changed),
            bundledFile("missing", "/ext/apps/missing.fap", missing),
        ]
        let fs = FakeFS()
        fs.files[files[0].target] = current
        fs.files[files[1].target] = Data("old".utf8)
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: [:]))

        let snapshot = try await inst.reconcilePackageStatus(manifest: manifest(files))

        XCTAssertEqual(snapshot.groups["base"], .updateAvailable)
        XCTAssertEqual(snapshot.files[files[0].target], .upToDate)
        XCTAssertEqual(snapshot.files[files[1].target], .needsUpdate)
        XCTAssertEqual(snapshot.files[files[2].target], .missing)
    }

    func testDetailedReconcileReportsValidationErrorWithoutClaimingMissing() async throws {
        let bytes = Data("firmware".utf8)
        let file = bundledFile("app", "/ext/apps/app.fap", bytes)
        let fs = FakeFS()
        fs.files[file.target] = bytes
        fs.seedState(.init(ledger: [file.target: entry(file.sha256, bytes)]))
        fs.checkedMD5FailuresRemaining = 2
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: [:]))

        let snapshot = try await inst.reconcilePackageStatus(manifest: manifest([file]))

        XCTAssertEqual(snapshot.groups["base"], .upToDate)
        XCTAssertEqual(snapshot.files[file.target], .validationError)
    }

    func testDetailedReconcileKnownMismatchWinsOverAnotherFilesValidationError() async throws {
        let changedBytes = Data("changed-expected".utf8)
        let errorBytes = Data("error-expected".utf8)
        let changed = bundledFile("changed", "/ext/apps/changed.fap", changedBytes)
        let error = bundledFile("error", "/ext/apps/error.fap", errorBytes)
        let fs = FakeFS()
        fs.files[changed.target] = Data("old".utf8)
        fs.files[error.target] = errorBytes
        fs.seedState(.init(ledger: [
            changed.target: entry(changed.sha256, changedBytes),
            error.target: entry(error.sha256, errorBytes),
        ]))
        fs.checkedMD5FailuresRemaining = 2
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: [:]))

        let snapshot = try await inst.reconcilePackageStatus(manifest: manifest([error, changed]))

        XCTAssertEqual(snapshot.groups["base"], .updateAvailable)
        XCTAssertEqual(snapshot.files[error.target], .validationError)
        XCTAssertEqual(snapshot.files[changed.target], .needsUpdate)
    }

    func testDetailedReconcileLegacyManifestUsesConservativeStatuses() async throws {
        let knownBytes = Data("known".utf8)
        let unknownBytes = Data("unknown".utf8)
        let missingBytes = Data("missing".utf8)
        let known = file("known", "/ext/apps/known.fap", knownBytes)
        let unknown = file("unknown", "/ext/apps/unknown.fap", unknownBytes)
        let missing = file("missing", "/ext/apps/missing.fap", missingBytes)
        let fs = FakeFS()
        fs.files[known.target] = knownBytes
        fs.files[unknown.target] = unknownBytes
        fs.seedState(.init(ledger: [known.target: entry(known.sha256, knownBytes)]))
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: [:]))

        let snapshot = try await inst.reconcilePackageStatus(
            manifest: manifest([known, unknown, missing]))

        XCTAssertEqual(snapshot.files[known.target], .upToDate)
        XCTAssertEqual(snapshot.files[unknown.target], .unknown)
        XCTAssertEqual(snapshot.files[missing.target], .missing)
    }

    func testReconcileReplacesStaleLedgerAfterFullMatch() async throws {
        let bytes = Data("firmware".utf8), target = "/ext/apps/a.fap"
        let file = bundledFile("a", target, bytes)
        let fs = FakeFS()
        fs.files[target] = bytes
        fs.seedState(.init(ledger: [target: .init(
            sha256: String(repeating: "0", count: 64), md5: String(repeating: "0", count: 32),
            releaseId: String(repeating: "0", count: 64))]))
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: [:]))

        let statuses = try await inst.reconcileStatus(manifest: manifest([file]))

        XCTAssertEqual(statuses["base"], .upToDate)
        let state = await fs.readState()
        XCTAssertEqual(try XCTUnwrap(state).ledger[target]?.sha256, file.sha256)
    }

    func testReconcileCurrentLedgerStillFlagsMissingTarget() async throws {
        let bytes = Data("firmware".utf8), target = "/ext/apps/a.fap"
        let file = bundledFile("a", target, bytes)
        let fs = FakeFS()
        fs.seedState(.init(ledger: [target: entry(file.sha256, bytes)]))
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: [:]))

        let statuses = try await inst.reconcileStatus(manifest: manifest([file]))

        XCTAssertEqual(statuses["base"], .updateAvailable)
        XCTAssertNil(fs.files["/ext/.tumoflip/install-state.json"])
    }

    func testReconcileCurrentLedgerStillFlagsChangedTarget() async throws {
        let bytes = Data("firmware".utf8), target = "/ext/apps/a.fap"
        let file = bundledFile("a", target, bytes)
        let fs = FakeFS()
        fs.files[target] = Data("changed".utf8)
        fs.seedState(.init(ledger: [target: entry(file.sha256, bytes)]))
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: [:]))

        let statuses = try await inst.reconcileStatus(manifest: manifest([file]))

        XCTAssertEqual(statuses["base"], .updateAvailable)
        XCTAssertNil(fs.files["/ext/.tumoflip/install-state.json"])
    }

    func testReconcileRejectsMissingChangedAndPartialGroups() async throws {
        let a = Data("a".utf8), b = Data("b".utf8)
        let files = [bundledFile("a", "/ext/a", a), bundledFile("b", "/ext/b", b)]
        for deviceFiles in [[:], ["/ext/a": Data("changed".utf8)], ["/ext/a": a]] {
            let fs = FakeFS()
            fs.files = deviceFiles
            let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: [:]))
            let statuses = try await inst.reconcileStatus(manifest: manifest(files))
            XCTAssertEqual(statuses["base"], .updateAvailable)
            let state = await fs.readState()
            XCTAssertTrue(state?.ledger.isEmpty ?? true)
        }
    }

    func testReconcileOldManifestKeepsLedgerFallback() async throws {
        let bytes = Data("present".utf8), target = "/ext/apps/a.fap"
        let legacyFile = file("a", target, bytes) // no manifest MD5
        let fs = FakeFS()
        fs.files[target] = bytes
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: [:]))

        let statuses = try await inst.reconcileStatus(manifest: manifest([legacyFile]))

        XCTAssertEqual(statuses["base"], .notInstalled)
        let oldManifestState = await fs.readState()
        XCTAssertNil(oldManifestState)
    }

    func testReconcileCleanupOnlyDeltaStaysPendingUntilLegacyRemoved() async throws {
        let bytes = Data("canonical".utf8)
        let canonical = "/ext/apps/new.fap", legacy = "/ext/apps/old.fap"
        let file = bundledFile("new", canonical, bytes)
        let cleanup: [TumoflipManifest.CleanupEntry] = [.init(canonical: canonical, legacy: legacy)]
        let fs = FakeFS()
        fs.files[canonical] = bytes
        fs.files[legacy] = Data("legacy".utf8)
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: [:]))

        let pending = try await inst.reconcileStatus(manifest: manifest([file], cleanup: cleanup))
        XCTAssertEqual(pending["base"], .updateAvailable)
        let pendingState = await fs.readState()
        XCTAssertNil(pendingState)

        fs.files[legacy] = nil
        let reconciled = try await inst.reconcileStatus(manifest: manifest([file], cleanup: cleanup))
        XCTAssertEqual(reconciled["base"], .upToDate)
        let reconciledState = await fs.readState()
        XCTAssertEqual(try XCTUnwrap(reconciledState).ledger[canonical]?.md5, file.md5)
    }

    func testRepeatedReconcileDoesNotRewriteDurableState() async throws {
        let bytes = Data("firmware".utf8), file = bundledFile("a", "/ext/a", Data("firmware".utf8))
        let fs = FakeFS()
        fs.files[file.target] = bytes
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: [:]))

        _ = try await inst.reconcileStatus(manifest: manifest([file]))
        let firstState = await fs.readState()
        let generation = try XCTUnwrap(firstState).generation
        let writes = fs.writeCount
        let repeated = try await inst.reconcileStatus(manifest: manifest([file]))
        XCTAssertEqual(repeated["base"], .upToDate)
        let repeatedState = await fs.readState()
        XCTAssertEqual(try XCTUnwrap(repeatedState).generation, generation)
        XCTAssertEqual(fs.writeCount, writes)
    }

    func testReconcileRepairsMissingCompatibilityProjectionWithoutReinstall() async throws {
        let bytes = Data("firmware".utf8)
        let file = bundledFile("a", "/ext/a", bytes)
        let fs = FakeFS()
        fs.files[file.target] = bytes
        fs.seedState(.init(ledger: [file.target: entry(file.sha256, bytes)]))
        let originalState = await fs.readState()
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: [:]))

        let statuses = try await inst.reconcileStatus(manifest: manifest([file]))

        XCTAssertEqual(statuses["base"], .upToDate)
        XCTAssertNotNil(fs.files["/ext/.tumoflip/install-state.json"])
        let packageState = try XCTUnwrap(fs.files["/ext/.tumoflip/package-state.txt"])
        XCTAssertTrue(String(decoding: packageState, as: UTF8.self).contains("Firmware: v"))
        let reconciledState = await fs.readState()
        XCTAssertEqual(reconciledState, originalState, "ledger generation must not change")
    }

    func testReconcileRetriesTransientDeviceHashFailure() async throws {
        let bytes = Data("firmware".utf8)
        let file = bundledFile("a", "/ext/a", bytes)
        let fs = FakeFS()
        fs.files[file.target] = bytes
        fs.checkedMD5FailuresRemaining = 1
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: [:]))

        let statuses = try await inst.reconcileStatus(manifest: manifest([file]))

        XCTAssertEqual(statuses["base"], .upToDate)
        let state = await fs.readState()
        XCTAssertEqual(try XCTUnwrap(state).ledger[file.target]?.md5, file.md5)
    }

    func testReconcileSurfacesPersistentDeviceHashFailure() async throws {
        let bytes = Data("firmware".utf8)
        let file = bundledFile("a", "/ext/a", bytes)
        let fs = FakeFS()
        fs.files[file.target] = bytes
        fs.checkedMD5FailuresRemaining = 2
        let inst = TumoflipInstaller(fs: fs, source: FakeSource(data: [:]))

        do {
            _ = try await inst.reconcileStatus(manifest: manifest([file]))
            XCTFail("expected transport failure")
        } catch FakeFS.Err.injected {
            // Expected: the UI can now keep its conservative ledger fallback.
        }
    }

    // MARK: - shared assertions

    private func assertThrows(_ expr: () async throws -> TumoflipInstaller.Outcome,
                              _ expected: TumoflipInstallError,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await expr(); XCTFail("expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? TumoflipInstallError, expected, file: file, line: line) }
    }
}
