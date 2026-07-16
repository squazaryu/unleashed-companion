import Foundation

/// Typed view over `runtime/capabilities`, understanding both the compact `feat`
/// token list (current tumoflip firmware — see `tumoflip_runtime.c`,
/// `TUMOFLIP_RUNTIME_CAPABILITIES`) and the legacy `features` list (older
/// firmware), plus each sub-protocol's own advertised schema version
/// (`status=2`, `trace=1`, `twin=1`, …). `feat` is canonical when present;
/// `features` is consulted only as a fallback for firmware that predates it.
struct RuntimeCapabilities: Equatable {
    let raw: [String: String]
    let featureTokens: Set<String>

    init(_ capabilities: [String: String]) {
        raw = capabilities
        if let feat = capabilities["feat"] {
            featureTokens = Set(feat.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        } else if let features = capabilities["features"] {
            featureTokens = Set(features.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        } else {
            featureTokens = []
        }
    }

    private func has(_ token: String, legacyToken: String? = nil, versionKey: String) -> Bool {
        if featureTokens.contains(token) { return true }
        if let legacyToken, featureTokens.contains(legacyToken) { return true }
        return raw[versionKey] != nil
    }

    var supportsStatus: Bool { raw["status"] != nil }
    var supportsTrace: Bool { has("trace", versionKey: "trace") }
    var supportsTwin: Bool { has("twin", versionKey: "twin") }
    var supportsPackages: Bool { has("pkg", legacyToken: "pkg_state", versionKey: "packages") }
    var supportsRadio: Bool { has("radio", legacyToken: "radio_v2", versionKey: "radio") }
    /// Transfer-activity reporting is available only when firmware explicitly
    /// advertises either the compact `transfer` token or legacy
    /// `transfer_activity` token.
    var supportsTransferActivity: Bool {
        featureTokens.contains("transfer_activity") || featureTokens.contains("transfer")
    }
    var supportsFabric: Bool { has("fabric", versionKey: "fabric") }
    var sessionVersion: Int? { raw["session"].flatMap(Int.init) }
}

/// Shared `key=value;key=value` parser for Runtime v2/v3 payloads — the same
/// shape as `runtime/capabilities` but used for `status`/`twin` response bodies,
/// which are plain UTF-8 strings rather than `Data` (already decoded by the
/// caller from the FAB2 response payload).
private func parseRuntimeFields(_ text: String) -> [String: String] {
    var out: [String: String] = [:]
    for pair in text.split(separator: ";") {
        let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard kv.count == 2 else { continue }
        out[String(kv[0])] = String(kv[1])
    }
    return out
}

/// `SubGhzRadioBrokerState` mirrored from the firmware's compact numeric encoding
/// (`docs/app-bridge-v2.md`), used by both `runtime/status` and `runtime/twin`.
enum RuntimeRadioState: Int {
    case idle = 0, acquired, probing, initialized, rx, tx, asyncRx, asyncTx, cleanup
    case externalPowerOn = 9, releasing, error

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .acquired: return "Acquired"
        case .probing: return "Probing"
        case .initialized: return "Initialized"
        case .rx: return "RX"
        case .tx: return "TX"
        case .asyncRx: return "Async RX"
        case .asyncTx: return "Async TX"
        case .cleanup: return "Cleanup"
        case .externalPowerOn: return "External power"
        case .releasing: return "Releasing"
        case .error: return "Error"
        }
    }
}

/// `runtime/status` — compact schema v2, read-only, one FAB2 response frame.
struct RuntimeStatus: Equatable {
    let schema: Int
    let firmwareVersion: String?
    let commit: String?
    let dirty: Bool?
    let origin: String?
    let api: String?
    let target: Int?
    let sdReady: Bool?
    let packageStatePresent: Bool?
    let sessionID: String?
    let bridgeOwner: String?
    let radioState: Int?
    let owner: String?

    var radioStateLabel: String? { radioState.flatMap(RuntimeRadioState.init)?.label }

    init?(_ payload: String) {
        let f = parseRuntimeFields(payload)
        guard let schemaVal = f["schema"].flatMap(Int.init) else { return nil }
        schema = schemaVal
        firmwareVersion = f["fw"]
        commit = f["commit"]
        dirty = f["dirty"].map { $0 == "1" }
        origin = f["origin"]
        api = f["api"]
        target = f["target"].flatMap(Int.init)
        sdReady = f["sd"].map { $0 == "1" }
        packageStatePresent = f["pkg"].map { $0 == "1" }
        sessionID = f["sid"]
        bridgeOwner = f["bo"]
        radioState = f["radio"].flatMap(Int.init)
        owner = f["owner"]
    }
}

/// One entry in the compact `runtime/trace` ring: `code,command,result`.
/// `code`: `r` received, `t` successful reply, `e` error, `s` session ownership.
/// `command`: first character of the related command (or owner name, for `s`).
/// `ok`: whether this traced event was an error (`e`) or not (`o`).
struct RuntimeTraceEntry: Equatable, Identifiable {
    /// Position within the parsed ring snapshot — stable across SwiftUI re-renders of
    /// the same `RuntimeTrace` value (unlike a value derived from `code`/`command`/`ok`,
    /// which can legitimately repeat across distinct ring slots).
    let id: Int
    let code: Character
    let command: Character
    let ok: Bool

    var codeLabel: String {
        switch code {
        case "r": return "recv"
        case "t": return "reply"
        case "e": return "error"
        case "s": return "session"
        default: return String(code)
        }
    }
}

/// `runtime/trace` — compact schema v1 ring snapshot, bounded to one FAB2 frame.
/// Payload shape: `schema=1;depth=8;count=2;drop=0|r,s,o|t,s,o`.
struct RuntimeTrace: Equatable {
    let schema: Int
    let depth: Int
    let count: Int
    let dropped: Int?
    let entries: [RuntimeTraceEntry]

    init?(_ payload: String) {
        let segments = payload.split(separator: "|", omittingEmptySubsequences: false)
        guard let header = segments.first else { return nil }
        let f = parseRuntimeFields(String(header))
        guard let schemaVal = f["schema"].flatMap(Int.init),
              let depthVal = f["depth"].flatMap(Int.init),
              let countVal = f["count"].flatMap(Int.init) else { return nil }
        schema = schemaVal
        depth = depthVal
        count = countVal
        dropped = f["drop"].flatMap(Int.init)
        let parsed: [(code: Character, command: Character, ok: Bool)] = segments.dropFirst().compactMap { segment in
            let comps = segment.split(separator: ",")
            guard comps.count == 3,
                  let code = comps[0].first, let command = comps[1].first, let result = comps[2].first
            else { return nil }
            return (code, command, result == "o")
        }
        entries = parsed.enumerated().map { index, e in
            RuntimeTraceEntry(id: index, code: e.code, command: e.command, ok: e.ok)
        }
    }
}

/// `runtime/twin` — compact Device Twin schema v1, read-only, one FAB2 frame.
/// Payload shape:
/// `schema=1;fw=...;cm=...;dy=...;sd=...;pkg=...;bat=...;chg=...;otg=...;heap=...;rf=...;ro=...;sid=...;bo=...`.
struct RuntimeTwin: Equatable {
    let schema: Int
    let firmwareVersion: String?
    let commit: String?
    let dirty: Bool?
    let sdReady: Bool?
    let packageStatePresent: Bool?
    let batteryPercent: Int?
    let charging: Bool?
    let otgEnabled: Bool?
    let maxHeapBlock: Int?
    let radioState: Int?
    let radioOwner: String?
    let sessionID: String?
    let bridgeOwner: String?

    var radioStateLabel: String? { radioState.flatMap(RuntimeRadioState.init)?.label }

    init?(_ payload: String) {
        let f = parseRuntimeFields(payload)
        guard let schemaVal = f["schema"].flatMap(Int.init) else { return nil }
        schema = schemaVal
        firmwareVersion = f["fw"]
        commit = f["cm"]
        dirty = f["dy"].map { $0 == "1" }
        sdReady = f["sd"].map { $0 == "1" }
        packageStatePresent = f["pkg"].map { $0 == "1" }
        batteryPercent = f["bat"].flatMap(Int.init)
        charging = f["chg"].map { $0 == "1" }
        otgEnabled = f["otg"].map { $0 == "1" }
        maxHeapBlock = f["heap"].flatMap(Int.init)
        radioState = f["rf"].flatMap(Int.init)
        radioOwner = f["ro"]
        sessionID = f["sid"]
        bridgeOwner = f["bo"]
    }
}

// MARK: - FlipperBLE Runtime requests

extension FlipperBLE {
    enum RuntimeDiagnosticsError: Error, Equatable, LocalizedError {
        case malformedPayload(String)

        var errorDescription: String? {
            switch self {
            case .malformedPayload(let command): return "The Flipper's \(command) reply didn't match the expected format."
            }
        }
    }

    /// Fetches `runtime/status` — always advertised wherever FAB2 Runtime exists.
    func runtimeStatus(timeout: TimeInterval = 5) async throws -> RuntimeStatus {
        let data = try await appBridgeRequest(appID: "runtime", command: "status", timeout: timeout)
        guard let text = String(data: data, encoding: .utf8), let status = RuntimeStatus(text) else {
            throw RuntimeDiagnosticsError.malformedPayload("status")
        }
        return status
    }

    /// Fetches `runtime/trace` — only on firmware advertising `trace` (`RuntimeCapabilities.supportsTrace`).
    func runtimeTrace(timeout: TimeInterval = 5) async throws -> RuntimeTrace {
        let data = try await appBridgeRequest(appID: "runtime", command: "trace", timeout: timeout)
        guard let text = String(data: data, encoding: .utf8), let trace = RuntimeTrace(text) else {
            throw RuntimeDiagnosticsError.malformedPayload("trace")
        }
        return trace
    }

    /// Fetches `runtime/twin` — only on firmware advertising `twin` (`RuntimeCapabilities.supportsTwin`).
    func runtimeTwin(timeout: TimeInterval = 5) async throws -> RuntimeTwin {
        let data = try await appBridgeRequest(appID: "runtime", command: "twin", timeout: timeout)
        guard let text = String(data: data, encoding: .utf8), let twin = RuntimeTwin(text) else {
            throw RuntimeDiagnosticsError.malformedPayload("twin")
        }
        return twin
    }
}
