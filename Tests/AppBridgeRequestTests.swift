import XCTest
@testable import UnleashedCompanion

/// Tests for the FAB2 request/response layer (issue #7): correlation, chunk
/// reassembly, strict decoder boundaries, response semantics (ping/pong, errors),
/// timeout/disconnect cleanup, and capability parsing. Transport-agnostic — no
/// CoreBluetooth or hardware needed.
final class AppBridgeRequestTests: XCTestCase {

    // MARK: - Helpers

    /// Build a (valid) FAB2 frame routed through the real decoder. Used for the
    /// request/response tests; all fields here stay within the wire contract.
    private func v2(_ appID: String, _ command: String, reqID: UInt32, flags: UInt8,
                    idx: UInt8, count: UInt8, payload: Data) -> AppBridgeFrame {
        let id = Array(appID.utf8), cmd = Array(command.utf8)
        var f = Data()
        f.append(contentsOf: AppBridgeFrame.magicV2)
        f.append(flags)
        f.append(UInt8(id.count)); f.append(UInt8(cmd.count))
        f.append(idx); f.append(count); f.append(0)
        f.append(UInt8(payload.count & 0xFF)); f.append(UInt8((payload.count >> 8) & 0xFF))
        f.append(UInt8(reqID & 0xFF)); f.append(UInt8((reqID >> 8) & 0xFF))
        f.append(UInt8((reqID >> 16) & 0xFF)); f.append(UInt8((reqID >> 24) & 0xFF))
        f.append(contentsOf: id); f.append(contentsOf: cmd); f.append(payload)
        guard let frame = AppBridgeFrame(decoding: f) else {
            fatalError("test built an invalid FAB2 frame")
        }
        return frame
    }

    private var resp: UInt8 { AppBridgeFrame.flagResponse }

    private final class FrameSink: @unchecked Sendable {
        private let lock = NSLock()
        private var sends: [[Data]] = []
        func capture(_ f: [Data]) { lock.lock(); sends.append(f); lock.unlock() }
        func waitSend(_ n: Int = 1) async -> [Data] {
            for _ in 0..<2000 {
                lock.lock(); let s = sends; lock.unlock()
                if s.count >= n { return s[n - 1] }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return []
        }
    }

    private func sentID(_ frames: [Data]) -> UInt32 { AppBridgeFrame(decoding: frames[0])!.requestID }
    private func appBridgeError(_ error: Error) -> AppBridgeError? { error as? AppBridgeError }

    private func start(_ coord: AppBridgeRequestCoordinator, _ appID: String, _ command: String,
                       payload: Data = Data(), timeout: TimeInterval = 2) -> Task<Data, Error> {
        Task { try await coord.request(appID: appID, command: command, payload: payload, timeout: timeout) }
    }

    // MARK: - Framing vectors

    func testFAB2RoundTrip() {
        let frames = AppBridgeFrame.encodeV2(appID: "runtime", command: "capabilities",
                                             payload: Data([9, 8, 7]), requestID: 0x01020304,
                                             flags: AppBridgeFrame.flagAckRequested)
        XCTAssertEqual(frames?.count, 1)
        let d = AppBridgeFrame(decoding: frames![0])
        XCTAssertEqual(d?.version, 2)
        XCTAssertEqual(d?.appID, "runtime")
        XCTAssertEqual(d?.command, "capabilities")
        XCTAssertEqual(d?.payload, Data([9, 8, 7]))
        XCTAssertEqual(d?.requestID, 0x01020304)
        XCTAssertEqual(d?.chunkCount, 1)
    }

    func testFAB2ChunkSplitting() {
        let payload = Data((0..<350).map { UInt8($0 & 0xFF) })
        let frames = AppBridgeFrame.encodeV2(appID: "a", command: "b", payload: payload, requestID: 7)
        XCTAssertEqual(frames?.count, 3)
        let decoded = frames!.map { AppBridgeFrame(decoding: $0)! }
        XCTAssertEqual(decoded.map { Int($0.chunkIndex) }, [0, 1, 2])
        XCTAssertTrue(decoded.allSatisfy { $0.chunkCount == 3 && $0.requestID == 7 })
        XCTAssertEqual(decoded.reduce(Data()) { $0 + $1.payload }, payload)
    }

    // MARK: - Strict decoder boundaries

    /// A known-good FAB2 frame: runtime/cap, reqID 5, payload [1,2]. Total 28 bytes.
    private func validV2Bytes() -> [UInt8] {
        let id = Array("runtime".utf8), cmd = Array("cap".utf8), pay: [UInt8] = [1, 2]
        var b = AppBridgeFrame.magicV2
        b += [AppBridgeFrame.flagResponse, UInt8(id.count), UInt8(cmd.count), 0, 1, 0,
              UInt8(pay.count & 0xFF), UInt8(pay.count >> 8), 5, 0, 0, 0]
        b += id + cmd + pay
        return b
    }

    func testDecoderAcceptsValidFrame() {
        XCTAssertNotNil(AppBridgeFrame(decoding: Data(validV2Bytes())))
    }

    func testDecoderRejectsBoundaryViolations() {
        func decode(_ transform: ([UInt8]) -> [UInt8]) -> AppBridgeFrame? {
            AppBridgeFrame(decoding: Data(transform(validV2Bytes())))
        }
        XCTAssertNil(decode { var b = $0; b[9] = 1; return b }, "reserved must be 0")
        XCTAssertNil(decode { var b = $0; b[4] = 0x08; return b }, "unknown flag bit")
        XCTAssertNil(decode { var b = $0; b[12] = 0; b[13] = 0; b[14] = 0; b[15] = 0; return b }, "response request id 0")
        XCTAssertNil(decode { var b = $0; b[8] = 0; return b }, "chunk count 0")
        XCTAssertNil(decode { var b = $0; b[7] = 1; b[8] = 1; return b }, "chunkIndex >= chunkCount")
        XCTAssertNil(decode { var b = $0; b[5] = 0; return b }, "appID length 0")
        XCTAssertNil(decode { $0 + [0xFF] }, "trailing byte")
        XCTAssertNil(decode { Array($0.prefix(10)) }, "shorter than header")
    }

    func testDecoderRejectsOversizedPayload() {
        let id = Array("a".utf8), cmd = Array("b".utf8)
        let pay = [UInt8](repeating: 0, count: 161)              // > 160 per-frame max
        var b = AppBridgeFrame.magicV2
        b += [0x02, UInt8(id.count), UInt8(cmd.count), 0, 1, 0,
              UInt8(161 & 0xFF), UInt8(161 >> 8), 1, 0, 0, 0]
        b += id + cmd + pay
        XCTAssertNil(AppBridgeFrame(decoding: Data(b)))
    }

    func testDecoderAcceptsZeroRequestIDForUnsolicitedEvents() {
        let id = Array("wifi_mapper".utf8)
        let cmd = Array("live_line".utf8)
        let pay = Array("-70 Ch: 6 AA:BB:CC:DD:EE:AA ESSID: LiveNet 11 04".utf8)
        var b = AppBridgeFrame.magicV2
        b += [0, UInt8(id.count), UInt8(cmd.count), 0, 1, 0,
              UInt8(pay.count & 0xFF), UInt8(pay.count >> 8), 0, 0, 0, 0]
        b += id + cmd + pay

        let frame = AppBridgeFrame(decoding: Data(b))
        XCTAssertEqual(frame?.version, 2)
        XCTAssertEqual(frame?.appID, "wifi_mapper")
        XCTAssertEqual(frame?.command, "live_line")
        XCTAssertEqual(frame?.requestID, 0)
        XCTAssertEqual(frame?.flags, 0)
        XCTAssertEqual(String(data: frame?.payload ?? Data(), encoding: .utf8), String(bytes: pay, encoding: .utf8))
    }

    func testDecoderRejectsInvalidUTF8() {
        var b = validV2Bytes()
        b[16] = 0xFF; b[17] = 0xFE                               // corrupt the appID bytes
        XCTAssertNil(AppBridgeFrame(decoding: Data(b)))
    }

    // MARK: - Capabilities (real firmware format)

    func testCapabilitiesRealFirmwarePayload() {
        // The exact string emitted by tumoflip_runtime.c (TUMOFLIP_RUNTIME_CAPABILITIES).
        let payload = Data(("runtime=1;fab=2;packages=2;legacy=1;payload=160;chunks=255;reassembly=512;"
                          + "features=request_id,chunking,error,capabilities,radio_status").utf8)
        let caps = FlipperBLE.parseCapabilities(payload)
        XCTAssertEqual(caps["runtime"], "1")
        XCTAssertEqual(caps["fab"], "2")
        XCTAssertEqual(caps["packages"], "2")
        XCTAssertEqual(caps["legacy"], "1")
        XCTAssertEqual(caps["payload"], "160")
        XCTAssertEqual(caps["chunks"], "255")
        XCTAssertEqual(caps["reassembly"], "512")
        // A value containing commas (the features list) is preserved verbatim.
        XCTAssertEqual(caps["features"], "request_id,chunking,error,capabilities,radio_status")
        XCTAssertTrue(FlipperBLE.parseCapabilities(Data()).isEmpty)
    }

    func testCapabilitiesJSONFallback() {
        let caps = FlipperBLE.parseCapabilities(Data(#"{"runtime":"1","fab":"2"}"#.utf8))
        XCTAssertEqual(caps["runtime"], "1")
        XCTAssertEqual(caps["fab"], "2")
    }

    // MARK: - Request / response success

    func testSingleChunkResponse() async throws {
        let sink = FrameSink()
        let coord = AppBridgeRequestCoordinator(send: { sink.capture($0) })
        let task = start(coord, "runtime", "capabilities")
        let id = sentID(await sink.waitSend())
        XCTAssertNotEqual(id, 0, "request id must never be zero")
        coord.ingest(v2("runtime", "capabilities", reqID: id, flags: resp, idx: 0, count: 1, payload: Data([1, 2, 3])))
        let data = try await task.value
        XCTAssertEqual(data, Data([1, 2, 3]))
    }

    func testMultiChunkReassembly() async throws {
        let sink = FrameSink()
        let coord = AppBridgeRequestCoordinator(send: { sink.capture($0) })
        let task = start(coord, "x", "y")
        let id = sentID(await sink.waitSend())
        coord.ingest(v2("x", "data", reqID: id, flags: resp, idx: 0, count: 3, payload: Data([1, 2])))
        coord.ingest(v2("x", "data", reqID: id, flags: resp, idx: 1, count: 3, payload: Data([3, 4])))
        coord.ingest(v2("x", "data", reqID: id, flags: resp, idx: 2, count: 3, payload: Data([5])))
        let data = try await task.value
        XCTAssertEqual(data, Data([1, 2, 3, 4, 5]))
    }

    // MARK: - Response semantics

    func testPingPongResolves() async throws {
        let sink = FrameSink()
        let coord = AppBridgeRequestCoordinator(send: { sink.capture($0) })
        let task = start(coord, "runtime", "ping")
        let id = sentID(await sink.waitSend())
        // Response command "pong" differs from request "ping" — must still resolve.
        coord.ingest(v2("runtime", "pong", reqID: id, flags: resp, idx: 0, count: 1, payload: Data([1])))
        let data = try await task.value
        XCTAssertEqual(data, Data([1]))
    }

    func testFirmwareErrorSurfaced() async throws {
        let sink = FrameSink()
        let coord = AppBridgeRequestCoordinator(send: { sink.capture($0) })
        let task = start(coord, "x", "y")
        let id = sentID(await sink.waitSend())
        let errFlags = AppBridgeFrame.flagResponse | AppBridgeFrame.flagError
        coord.ingest(v2("x", "error", reqID: id, flags: errFlags, idx: 0, count: 1, payload: Data("boom".utf8)))
        do { _ = try await task.value; XCTFail("expected firmwareError") }
        catch { XCTAssertEqual(appBridgeError(error), .firmwareError("boom")) }
    }

    func testResponseAppIDMismatchRejected() async throws {
        let sink = FrameSink()
        let coord = AppBridgeRequestCoordinator(send: { sink.capture($0) })
        let task = start(coord, "runtime", "capabilities")
        let id = sentID(await sink.waitSend())
        coord.ingest(v2("other", "capabilities", reqID: id, flags: resp, idx: 0, count: 1, payload: Data()))
        await assertProtocolViolation(task)
    }

    func testResponseCommandConsistentAcrossChunks() async throws {
        let sink = FrameSink()
        let coord = AppBridgeRequestCoordinator(send: { sink.capture($0) })
        let task = start(coord, "runtime", "x")
        let id = sentID(await sink.waitSend())
        coord.ingest(v2("runtime", "data", reqID: id, flags: resp, idx: 0, count: 2, payload: Data([1])))
        coord.ingest(v2("runtime", "other", reqID: id, flags: resp, idx: 1, count: 2, payload: Data([2]))) // command changed
        await assertProtocolViolation(task)
    }

    // MARK: - Validation boundaries (reassembly)

    func testOutOfOrderChunkRejected() async throws {
        let sink = FrameSink()
        let coord = AppBridgeRequestCoordinator(send: { sink.capture($0) })
        let task = start(coord, "x", "y")
        let id = sentID(await sink.waitSend())
        coord.ingest(v2("x", "data", reqID: id, flags: resp, idx: 1, count: 2, payload: Data([9]))) // expected 0
        await assertProtocolViolation(task)
    }

    func testDuplicateChunkRejected() async throws {
        let sink = FrameSink()
        let coord = AppBridgeRequestCoordinator(send: { sink.capture($0) })
        let task = start(coord, "x", "y")
        let id = sentID(await sink.waitSend())
        coord.ingest(v2("x", "data", reqID: id, flags: resp, idx: 0, count: 2, payload: Data([1])))
        coord.ingest(v2("x", "data", reqID: id, flags: resp, idx: 0, count: 2, payload: Data([1])))
        await assertProtocolViolation(task)
    }

    func testOversizedResponseRejected() async throws {
        let sink = FrameSink()
        let coord = AppBridgeRequestCoordinator(send: { sink.capture($0) })
        let task = start(coord, "x", "y")
        let id = sentID(await sink.waitSend())
        let chunk = Data(count: 160)                    // valid per-frame max
        coord.ingest(v2("x", "data", reqID: id, flags: resp, idx: 0, count: 4, payload: chunk))
        coord.ingest(v2("x", "data", reqID: id, flags: resp, idx: 1, count: 4, payload: chunk))
        coord.ingest(v2("x", "data", reqID: id, flags: resp, idx: 2, count: 4, payload: chunk))
        coord.ingest(v2("x", "data", reqID: id, flags: resp, idx: 3, count: 4, payload: chunk)) // 640 > 512
        await assertProtocolViolation(task)
    }

    // MARK: - Correlation

    func testConcurrentRequestsResolveIndependently() async throws {
        let sink = FrameSink()
        let coord = AppBridgeRequestCoordinator(send: { sink.capture($0) })
        let t1 = start(coord, "a", "x")
        let id1 = sentID(await sink.waitSend(1))
        let t2 = start(coord, "b", "y")
        let id2 = sentID(await sink.waitSend(2))
        XCTAssertNotEqual(id1, id2)
        coord.ingest(v2("b", "y", reqID: id2, flags: resp, idx: 0, count: 1, payload: Data([2])))
        coord.ingest(v2("a", "x", reqID: id1, flags: resp, idx: 0, count: 1, payload: Data([1])))
        let d1 = try await t1.value, d2 = try await t2.value
        XCTAssertEqual(d1, Data([1]))
        XCTAssertEqual(d2, Data([2]))
    }

    func testEventFrameCannotCompleteRequest() async throws {
        let sink = FrameSink()
        let coord = AppBridgeRequestCoordinator(send: { sink.capture($0) })
        let task = start(coord, "runtime", "capabilities")
        let id = sentID(await sink.waitSend())
        coord.ingest(v2("runtime", "capabilities", reqID: id, flags: 0, idx: 0, count: 1, payload: Data([0]))) // event
        coord.ingest(v2("runtime", "capabilities", reqID: id, flags: resp, idx: 0, count: 1, payload: Data([7])))
        let data = try await task.value
        XCTAssertEqual(data, Data([7]))
    }

    func testStrayResponseIgnored() async throws {
        let sink = FrameSink()
        let coord = AppBridgeRequestCoordinator(send: { sink.capture($0) })
        coord.ingest(v2("z", "z", reqID: 999, flags: resp, idx: 0, count: 1, payload: Data([1])))
        let task = start(coord, "x", "y")
        let id = sentID(await sink.waitSend())
        coord.ingest(v2("x", "y", reqID: id, flags: resp, idx: 0, count: 1, payload: Data([5])))
        let data = try await task.value
        XCTAssertEqual(data, Data([5]))
    }

    // MARK: - Cleanup

    func testTimeoutCleansUp() async throws {
        let sink = FrameSink()
        let coord = AppBridgeRequestCoordinator(send: { sink.capture($0) })
        let task = start(coord, "x", "y", timeout: 0.1)
        do { _ = try await task.value; XCTFail("expected timeout") }
        catch { XCTAssertEqual(appBridgeError(error), .timeout) }
    }

    func testDisconnectFailsPending() async throws {
        let sink = FrameSink()
        let coord = AppBridgeRequestCoordinator(send: { sink.capture($0) })
        let task = start(coord, "x", "y", timeout: 5)
        _ = await sink.waitSend()
        coord.failAll(.disconnected)
        do { _ = try await task.value; XCTFail("expected disconnected") }
        catch { XCTAssertEqual(appBridgeError(error), .disconnected) }
    }

    func testReservedIDsNonZeroAndDistinct() {
        let coord = AppBridgeRequestCoordinator(send: { _ in })
        let a = coord.reserveID(), b = coord.reserveID()
        XCTAssertNotEqual(a, 0)
        XCTAssertNotEqual(b, 0)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - shared assertion

    private func assertProtocolViolation(_ task: Task<Data, Error>,
                                         file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await task.value; XCTFail("expected protocolViolation", file: file, line: line) }
        catch {
            if case .protocolViolation = appBridgeError(error) {} else {
                XCTFail("expected protocolViolation, got \(error)", file: file, line: line)
            }
        }
    }
}
