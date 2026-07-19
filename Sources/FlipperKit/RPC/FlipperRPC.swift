import Foundation
import Combine
import SwiftProtobuf

enum FlipperRPCError: Error, LocalizedError {
    case notReady
    case status(PB_CommandStatus)
    case timeout
    case decode

    var errorDescription: String? {
        switch self {
        case .notReady:        return "Flipper is not connected"
        case .status(.errorContinuousCommandInterrupted):
            return "Another Flipper command interrupted the transfer. Wait for the connection to settle, then retry."
        case .status(let s):   return "Flipper error: \(s)"
        case .timeout:         return "Command timed out"
        case .decode:          return "Failed to decode response"
        }
    }
}

/// Flipper's protobuf server accepts only one response-bearing command at a time.
/// In particular, starting another command while a multi-frame Storage request is
/// active aborts that request with `errorContinuousCommandInterrupted`.
final class RPCCommandGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if held {
                waiters.append(continuation)
                lock.unlock()
            } else {
                held = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func release() {
        lock.lock()
        let next = waiters.isEmpty ? nil : waiters.removeFirst()
        if next == nil { held = false }
        lock.unlock()
        next?.resume()
    }

    func withPermit<T>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }
}

/// Flipper RPC session: speaks length-delimited `PB_Main` protobuf over the
/// serial BLE pipe. Matches streaming responses by `command_id` and exposes an
/// async/await command API plus a publisher for unsolicited frames (screen
/// stream, desktop status, app state).
final class FlipperRPC: ObservableObject {
    static let shared = FlipperRPC()

    let ble: FlipperBLE
    /// Unsolicited frames (command_id == 0): screen frames, desktop status, etc.
    let unsolicited = PassthroughSubject<PB_Main, Never>()

    private var rxBuffer = Data()
    private var nextCommandID: UInt32 = 1
    private let lock = NSLock()
    private let commandGate = RPCCommandGate()
    private var cancellable: AnyCancellable?

    private struct Pending {
        var accumulated: [PB_Main] = []
        let continuation: CheckedContinuation<[PB_Main], Error>
    }
    private var pending: [UInt32: Pending] = [:]

    private var stateCancellable: AnyCancellable?

    init(ble: FlipperBLE = .shared) {
        self.ble = ble
        cancellable = ble.serialIn.sink { [weak self] data in
            self?.ingest(data)
        }
        // Fail in-flight requests immediately on disconnect instead of letting
        // them hang until their timeout.
        stateCancellable = ble.$state.sink { [weak self] state in
            if state != .ready { self?.failAllPending(FlipperRPCError.notReady) }
        }
    }

    private func failAllPending(_ error: Error) {
        lock.lock()
        let waiters = pending
        pending.removeAll()
        rxBuffer.removeAll()
        lock.unlock()
        for (_, p) in waiters { p.continuation.resume(throwing: error) }
    }

    // MARK: - Sending

    /// Build and send a command, returning every response frame until the
    /// Flipper signals `has_next == false`. The closure receives a Main with a
    /// fresh `command_id` already assigned — set its `content` and any fields.
    @discardableResult
    func command(timeout: TimeInterval = 30,
                 _ configure: @escaping (inout PB_Main) -> Void) async throws -> [PB_Main] {
        try await commandStreaming(timeout: timeout, [configure])
    }

    /// Send a multi-frame request: all frames share one `command_id`, every frame
    /// but the last carries `has_next = true`. Waits for the single response set.
    /// Used for chunked Storage writes.
    ///
    /// `timeout` is a STALL threshold, not a ceiling on total duration: it resets every
    /// time a frame is successfully handed to the BLE layer, and again covers the tail
    /// wait for the final response after the last frame. A single-frame `command()` call
    /// behaves exactly as before (one frame ⇒ no distinction from an absolute timeout).
    /// A multi-frame write can legitimately run for minutes on a large file without
    /// tripping this, as long as it keeps making progress — only a genuine stall (no
    /// frame progress, and no final reply) for `timeout` seconds in a row fires it. A
    /// fixed absolute timeout here previously made large writes (e.g. a several-MB .fap)
    /// fail right as the progress bar reached 100% locally-sent, while still waiting on
    /// the Flipper's final write confirmation — see the `move()`/`read()` timeout bumps
    /// above for the same underlying class of bug on other size-scaling operations.
    @discardableResult
    func commandStreaming(timeout: TimeInterval = 60,
                          onFrameSent: (@Sendable (Int) -> Void)? = nil,
                          _ configures: [(inout PB_Main) -> Void]) async throws -> [PB_Main] {
        guard !configures.isEmpty else { return [] }

        // The serial transport can queue bytes, but the Flipper RPC server cannot
        // execute overlapping response-bearing commands. Hold one FIFO permit for
        // the complete request, including every write frame and the final response.
        await commandGate.acquire()
        defer { commandGate.release() }
        try Task.checkCancellation()

        // Tolerate the connected→ready discovery gap and brief reconnect blips:
        // wait a moment for the link instead of failing the instant it isn't ready.
        if ble.state != .ready {
            guard await ble.waitUntilReady() else { throw FlipperRPCError.notReady }
        }
        // Refuse RPC while the Buddy app owns the serial channel (see buddyMode).
        guard !ble.buddyMode else { throw FlipperRPCError.notReady }

        lock.lock()
        let id = nextCommandID
        nextCommandID &+= 1
        if nextCommandID == 0 { nextCommandID = 1 }
        lock.unlock()

        var frames: [Data] = []
        for (index, configure) in configures.enumerated() {
            var main = PB_Main()
            main.commandID = id
            main.hasNext_p = index < configures.count - 1
            configure(&main)
            frames.append(try Self.delimited(main))
        }

        let progress = StallClock()
        return try await withThrowingTaskGroup(of: [PB_Main].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    self.lock.lock()
                    self.pending[id] = Pending(continuation: cont)
                    self.lock.unlock()
                    // Send each frame only after the Flipper acks the previous
                    // one (writeSerial's completion). This paces uploads to the
                    // real link speed — blasting frames overran the Flipper and
                    // dropped the link mid-write. Progress now tracks actual acks.
                    Task {
                        for (i, frame) in frames.enumerated() {
                            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                                self.ble.writeSerial(frame) { c.resume() }
                            }
                            progress.touch()   // sync — no actor hop on the hot per-chunk path
                            onFrameSent?(i + 1)
                        }
                    }
                }
            }
            group.addTask {
                // Poll rather than one long sleep so a live transfer that keeps
                // resetting `progress` never trips this, no matter how long it runs.
                while true {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    if progress.stalled(for: timeout) {
                        throw FlipperRPCError.timeout
                    }
                }
            }
            defer { group.cancelAll() }
            let result = try await group.next()!
            return result
        }
    }

    /// Tracks "time since the last sign of life" for `commandStreaming`'s stall
    /// watchdog — reset on every frame successfully handed off, not just once at start.
    /// A plain lock, not an actor: `touch()` runs once per chunk (tens of thousands of
    /// times for a multi-MB write), and an actor hop there was measurable per-chunk
    /// overhead across that many calls; a lock is synchronous, no suspension point.
    private final class StallClock: @unchecked Sendable {
        private let lock = NSLock()
        private var last = Date()
        func touch() { lock.lock(); last = Date(); lock.unlock() }
        func stalled(for timeout: TimeInterval) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return Date().timeIntervalSince(last) >= timeout
        }
    }

    /// Fire-and-forget: send a frame without waiting for a matched response
    /// (used for input events and stream start/stop which the Flipper answers
    /// with an Empty we don't need to block on).
    func send(_ configure: (inout PB_Main) -> Void) {
        guard ble.state == .ready, !ble.buddyMode else { return }
        var main = PB_Main()
        main.commandID = 0
        configure(&main)
        if let frame = try? Self.delimited(main) { ble.writeSerial(frame) }
    }

    // MARK: - Receiving

    private func ingest(_ data: Data) {
        // Buddy passthrough owns the serial channel — don't parse its JSON as RPC,
        // and keep the RPC buffer empty so it starts clean when Buddy mode ends.
        if ble.buddyMode { lock.lock(); rxBuffer.removeAll(); lock.unlock(); return }
        lock.lock()
        rxBuffer.append(data)
        var frames: [PB_Main] = []
        while true {
            guard let (length, headerLen) = Self.readVarint(rxBuffer) else { break }
            let total = headerLen + Int(length)
            guard rxBuffer.count >= total else { break }
            let body = rxBuffer.subdata(in: headerLen..<total)
            rxBuffer.removeSubrange(0..<total)
            if let main = try? PB_Main(serializedData: body) {
                frames.append(main)
            }
        }
        var toResolve: [(Pending, [PB_Main]?, Error?)] = []
        var unsolicitedFrames: [PB_Main] = []
        for main in frames {
            let id = main.commandID
            if id != 0, var p = pending[id] {
                p.accumulated.append(main)
                if main.hasNext_p {
                    pending[id] = p
                } else {
                    pending.removeValue(forKey: id)
                    if main.commandStatus != .ok {
                        toResolve.append((p, nil, FlipperRPCError.status(main.commandStatus)))
                    } else {
                        toResolve.append((p, p.accumulated, nil))
                    }
                }
            } else {
                unsolicitedFrames.append(main)
            }
        }
        lock.unlock()

        for (p, value, error) in toResolve {
            if let error = error { p.continuation.resume(throwing: error) }
            else { p.continuation.resume(returning: value ?? []) }
        }
        for f in unsolicitedFrames { unsolicited.send(f) }
    }

    // MARK: - Wire format helpers

    /// Serialize a Main and prepend a protobuf base-128 varint length.
    static func delimited(_ main: PB_Main) throws -> Data {
        let body: Data = try main.serializedData()
        var out = Data()
        var len = UInt64(body.count)
        repeat {
            var byte = UInt8(len & 0x7F)
            len >>= 7
            if len != 0 { byte |= 0x80 }
            out.append(byte)
        } while len != 0
        out.append(contentsOf: body)
        return out
    }

    /// Read a base-128 varint from the front of `data`.
    /// Returns (value, bytesConsumed) or nil if incomplete.
    static func readVarint(_ data: Data) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var i = 0
        for byte in data {
            result |= UInt64(byte & 0x7F) << shift
            i += 1
            if byte & 0x80 == 0 { return (result, i) }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }
}
