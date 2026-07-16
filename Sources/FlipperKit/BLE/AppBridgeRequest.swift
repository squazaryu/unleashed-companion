import Foundation

/// Typed failures from the FAB2 request/response layer.
enum AppBridgeError: Error, Equatable, LocalizedError {
    case notNegotiated              // FAB2 not available on this firmware / link
    case encodeFailed               // header fields out of range
    case timeout
    case disconnected
    case firmwareError(String)      // firmware replied with the error flag set
    case protocolViolation(String)  // duplicate / out-of-order / mixed / oversized response

    var errorDescription: String? {
        switch self {
        case .notNegotiated: return "This firmware doesn't support App Bridge v2."
        case .encodeFailed: return "Couldn't encode the request (a field was out of range)."
        case .timeout: return "The Flipper didn't respond in time."
        case .disconnected: return "The Flipper disconnected before responding."
        case .firmwareError(let token): return "Flipper reported: \(Self.friendlyToken(token))"
        case .protocolViolation(let reason): return "Unexpected response from the Flipper (\(reason))."
        }
    }

    /// The tumoflip firmware's compact error tokens (`badcmd`, `chunk`, `owner`, …) are
    /// stable but terse; map the ones we know to a short human phrase and fall back to
    /// the raw token for anything newer than this client recognizes.
    private static func friendlyToken(_ token: String) -> String {
        switch token {
        case "badcmd": return "unsupported command"
        case "chunk": return "request can't be split into chunks"
        case "owner": return "invalid session owner"
        case "payload": return "invalid request payload"
        case "busy": return "another TumoFabric session owns the node"
        case "session": return "TumoFabric session expired or mismatched"
        case "seq": return "TumoFabric sequence is out of order"
        case "range": return "TumoFabric counter reached its limit"
        case "stopped": return "open TumoNet Gateway on the Flipper and press Start"
        case "rf_unavailable": return "Module One CC1101 is unavailable"
        case "storage": return "the Flipper couldn't write the TumoNet inbox"
        case "delivery_failed": return "TumoNet delivery failed"
        default: return token.isEmpty ? "unknown error" : token
        }
    }
}

/// Correlates FAB2 requests with their (possibly chunked) responses.
///
/// Transport-agnostic so it can be unit-tested without CoreBluetooth: it is handed
/// a `send` closure for outgoing frames, and fed incoming *response* frames via
/// `ingest`. All state lives on one serial queue, so frame order is preserved and
/// each pending request resolves exactly once.
///
/// Guarantees:
///  • request IDs are monotonic, never zero, never collide with an in-flight request;
///  • a request completes only from response frames carrying its exact ID, app_id and command;
///  • response chunks must arrive in order (0..count-1) — no gaps, dupes, reorder, or
///    count change — and reassemble to at most `responsePayloadMax` bytes;
///  • every pending request resolves once: success, firmware error, timeout, or disconnect.
final class AppBridgeRequestCoordinator: @unchecked Sendable {
    // @unchecked Sendable: every mutable field is touched only on `queue` (serial),
    // so cross-thread access is internally synchronised.

    /// Max reassembled logical response payload (firmware-compatible).
    static let responsePayloadMax = 512

    private final class Pending {
        let token = UUID()
        let appID: String
        let command: String          // the REQUEST command (for diagnostics only)
        var respCommand: String?     // the RESPONSE command, fixed by the first chunk
        var count: Int = -1          // learned from the first response chunk
        var next: Int = 0            // next expected chunk index
        var buffer = Data()
        let continuation: CheckedContinuation<Data, Error>
        init(appID: String, command: String, _ c: CheckedContinuation<Data, Error>) {
            self.appID = appID; self.command = command; self.continuation = c
        }
    }

    private let queue = DispatchQueue(label: "com.tumoflip.appbridge.requests")
    private var pending: [UInt32: Pending] = [:]
    private var lastID: UInt32 = 0
    private let send: ([Data]) -> Void

    init(send: @escaping ([Data]) -> Void) { self.send = send }

    // MARK: - ID allocation

    /// Next monotonic, nonzero request ID that isn't currently in flight. Must run
    /// on `queue`.
    private func allocateID() -> UInt32 {
        repeat {
            lastID = lastID &+ 1
            if lastID == 0 { lastID = 1 }     // wrap skips zero
        } while pending[lastID] != nil         // never collide with a live request
        return lastID
    }

    /// Reserve an ID for a fire-and-forget FAB2 send (no response awaited). Kept
    /// distinct from any in-flight awaited request at allocation time.
    func reserveID() -> UInt32 { queue.sync { allocateID() } }

    // MARK: - Request

    /// Send a FAB2 request and await its correlated, reassembled response payload.
    func request(appID: String, command: String, payload: Data,
                 timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            queue.async {
                let id = self.allocateID()
                guard let frames = AppBridgeFrame.encodeV2(
                    appID: appID, command: command, payload: payload,
                    requestID: id, flags: AppBridgeFrame.flagAckRequested) else {
                    cont.resume(throwing: AppBridgeError.encodeFailed); return
                }
                let p = Pending(appID: appID, command: command, cont)
                self.pending[id] = p
                self.send(frames)

                let token = p.token
                self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self else { return }
                    // Only expire if THIS request is still the one holding the id.
                    if let cur = self.pending[id], cur.token == token {
                        self.pending[id] = nil
                        cur.continuation.resume(throwing: AppBridgeError.timeout)
                    }
                }
            }
        }
    }

    // MARK: - Incoming responses

    /// Feed an incoming frame. Only FAB2 *response* frames matching a live request
    /// are consumed; anything else is ignored (events are handled elsewhere).
    func ingest(_ frame: AppBridgeFrame) {
        queue.async { self.handle(frame) }
    }

    private func handle(_ frame: AppBridgeFrame) {
        guard frame.version == 2, frame.isResponse else { return }
        guard let p = pending[frame.requestID] else { return }   // unknown / already-resolved → ignore

        func fail(_ e: AppBridgeError) {
            pending[frame.requestID] = nil
            p.continuation.resume(throwing: e)
        }

        // The response must echo the request's app_id. The command may legitimately
        // DIFFER from the request (e.g. Runtime `ping` -> `pong`), so it is NOT required
        // to equal the request command — only to stay consistent across the response's
        // own chunks (checked below).
        guard frame.appID == p.appID else {
            fail(.protocolViolation("response app_id mismatch")); return
        }
        // Firmware-signalled error (error flag; firmware sends command "error"): surface
        // its payload as a typed firmwareError rather than a protocol violation.
        if frame.isError {
            let msg = String(data: frame.payload, encoding: .utf8) ?? ""
            fail(.firmwareError(msg.isEmpty ? "firmware error" : msg)); return
        }
        // Command must be consistent across the chunks of one response (ping->pong is
        // fine, but every chunk of that pong must say "pong").
        if let rc = p.respCommand {
            guard frame.command == rc else {
                fail(.protocolViolation("response command changed mid-stream")); return
            }
        } else {
            p.respCommand = frame.command
        }
        // Chunk bookkeeping.
        let count = Int(frame.chunkCount)
        guard count >= 1 else { fail(.protocolViolation("zero chunk count")); return }
        if p.count < 0 { p.count = count }
        guard count == p.count else { fail(.protocolViolation("chunk count changed mid-stream")); return }
        guard Int(frame.chunkIndex) == p.next else {
            fail(.protocolViolation("duplicate or out-of-order chunk")); return
        }
        guard p.buffer.count + frame.payload.count <= Self.responsePayloadMax else {
            fail(.protocolViolation("response exceeds \(Self.responsePayloadMax) bytes")); return
        }
        p.buffer.append(frame.payload)
        p.next += 1
        if p.next == p.count {
            pending[frame.requestID] = nil
            p.continuation.resume(returning: p.buffer)
        }
    }

    // MARK: - Teardown

    /// Fail every pending request once (link dropped / RPC reset).
    func failAll(_ error: AppBridgeError) {
        queue.async {
            let all = self.pending
            self.pending.removeAll()
            for (_, p) in all { p.continuation.resume(throwing: error) }
        }
    }
}
