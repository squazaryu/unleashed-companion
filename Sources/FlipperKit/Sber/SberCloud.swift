import Foundation
import Security
import CryptoKit
import os

private let slog = Logger(subsystem: "com.tumoflip.unleashedcompanion", category: "sber")

/// Direct Sber smart-home cloud control — lets the iPhone toggle the relay
/// WITHOUT the Mac / Home Assistant. Mirrors the `sberdevices` HA integration:
/// OAuth token → gateway JWT (companion endpoint) → PUT device state.
enum SberAPI {
    static let authEndpoint    = "https://online.sberbank.ru/CSAFront/oidc/authorize.do"
    static let tokenEndpoint   = "https://online.sberbank.ru:4431/CSAFront/api/service/oidc/v3/token"
    static let companionToken  = "https://companion.devices.sberbank.ru/v13/smarthome/token"
    static let gatewayBase     = "https://gateway.iot.sberdevices.ru/gateway/v1"
    static let clientID        = "b1f0f0c6-fcb0-4ece-8374-6b614ebe3d42"
    static let redirectURI     = "companionapp://host"
    static let userAgent       = "Salute+prod%2F24.08.1.15602+%28Android+34%3B+Google+sdk_gphone64_arm64%29"
    static let defaultDeviceID = ""   // set per-user in the Bridge tab (no personal id baked into the build)
}

struct SberToken: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Double?   // epoch seconds

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case expiresIn = "expires_in"
    }

    init(accessToken: String, refreshToken: String, expiresAt: Double?) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = (try? c.decode(String.self, forKey: .refreshToken)) ?? ""
        if let at = try? c.decode(Double.self, forKey: .expiresAt) {
            expiresAt = at
        } else if let ein = try? c.decode(Double.self, forKey: .expiresIn) {
            expiresAt = Date().timeIntervalSince1970 + ein
        } else { expiresAt = nil }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accessToken, forKey: .accessToken)
        try c.encode(refreshToken, forKey: .refreshToken)
        try c.encodeIfPresent(expiresAt, forKey: .expiresAt)
    }

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date().timeIntervalSince1970 > (expiresAt - 60)  // refresh 60s early
    }
}

enum SberError: Error, LocalizedError {
    case noToken, http(Int, String), badResponse, refreshFailed(String), step(String, String)
    var errorDescription: String? {
        switch self {
        case .noToken:               return "No Sber token imported"
        case .http(let c, let b):    return "Sber HTTP \(c): \(b.prefix(120))"
        case .badResponse:           return "Unexpected Sber response"
        case .refreshFailed(let m):  return "Token refresh failed: \(m)"
        case .step(let s, let m):    return "[\(s)] \(m)"
        }
    }
}

/// Thread-safe holder for the last TLS-trust outcome, surfaced into the app's
/// Activity log (device os_log isn't reachable over idevicesyslog).
final class SberTrustDiag {
    static let shared = SberTrustDiag()
    private let lock = NSLock()
    private var _history: [String] = []
    var last: String { lock.lock(); defer { lock.unlock() }; return _history.last ?? "trust: not invoked" }
    var history: [String] { lock.lock(); defer { lock.unlock() }; return _history }
    func reset() { lock.lock(); _history = []; lock.unlock() }
    func set(_ s: String) { lock.lock(); _history.append(s); lock.unlock(); slog.notice("\(s, privacy: .public)") }
}

/// Pins the bundled Russian Trusted Root CA for Sber hosts only (iOS doesn't
/// trust it by default). All other hosts use default system evaluation.
final class SberTrustDelegate: NSObject, URLSessionDelegate {
    private let anchors: [SecCertificate]

    /// Russian Trusted Root CA (DER, base64) embedded directly so trust never
    /// depends on a bundle-resource lookup. iOS does not ship this CA.
    private static let rootCADER = "MIIFwjCCA6qgAwIBAgICEAAwDQYJKoZIhvcNAQELBQAwcDELMAkGA1UEBhMCUlUxPzA9BgNVBAoMNlRoZSBNaW5pc3RyeSBvZiBEaWdpdGFsIERldmVsb3BtZW50IGFuZCBDb21tdW5pY2F0aW9uczEgMB4GA1UEAwwXUnVzc2lhbiBUcnVzdGVkIFJvb3QgQ0EwHhcNMjIwMzAxMjEwNDE1WhcNMzIwMjI3MjEwNDE1WjBwMQswCQYDVQQGEwJSVTE/MD0GA1UECgw2VGhlIE1pbmlzdHJ5IG9mIERpZ2l0YWwgRGV2ZWxvcG1lbnQgYW5kIENvbW11bmljYXRpb25zMSAwHgYDVQQDDBdSdXNzaWFuIFRydXN0ZWQgUm9vdCBDQTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAMfFOZ8pUAL3+r2nqqE0Zp52selXsKGFYoG0GM5bwz1bSFtCt+AZQMhkWQheI3poZAToYJu69pHLKS6QXBiwBC1cvzYmUYKMYZC7jE5YhEU2bSL0mX7NaMxMDmH2/NwuOVRj8OImVa5s1F4Uzn4Kv3PFlDBjjSjXKVY9kmjUBsXQrIHeaqmUIsPIlNWUnimXS0I0abExqkbdrXbXYwCOXhOO2pDUx3ckmJlCMUGacUTnylyQW2VsJIyIGA8V0xzdaeUXg0VZ6ZmNUr5YBer/EAOLPb8NYpsAhJe2mXjMB/J9HNsoFMBFJ0lLOT/+dQvjbdRZoOT8eqJpWnVDU+QL/qEZnz57N88OWM3rabJkRNdU/Z7x5SFIM9FrqtN8xewsiBWBI0K6XFuOBOTD4V08o4TzJ8+Ccq5XlCUW2L48pZNCYuBDfBh7FxkB7qDgGDiaftEkZZfApRg2E+M9G8wkNKTPLDc4wH0FDTijhgxR3Y4PiS1HL2Zhw7bD3CbslmEGgfnnZojNkJtcLeBHBLa52/dSwNU4WWLubaYSiAmA9IUMX1/RpfpxOxd4Ykmhz97oFbUaDJFipIggx5sXePAlkTdWnv+RWBxlJwMQ25oEHmRguNYf4Zr/Rxr9cS93Y+mdXIZaBEE0KS2iLRqaOiWBki9IMQU4phqPOBAaG7A+eP8PAgMBAAGjZjBkMB0GA1UdDgQWBBTh0YHlzlpfBKrS6badZrHF+qwshzAfBgNVHSMEGDAWgBTh0YHlzlpfBKrS6badZrHF+qwshzASBgNVHRMBAf8ECDAGAQH/AgEEMA4GA1UdDwEB/wQEAwIBhjANBgkqhkiG9w0BAQsFAAOCAgEAALIY1wkilt/urfEVM5vKzr6utOeDWCUczmWX/RX4ljpRdgF+5fAIS4vHtmXkqpSCOVeWUrJV9QvZn6L227ZwuE15cWi8DCDal3Ue90WgAJJZMfTshN4OI8cqW9E4EG9wglbEtMnObHlms8F3CHmrw3k6KmUkWGoa+/ENmcVl68u/cMRl1JbW2bM+/3A+SAg2c6iPDlehczKx2oa95QW0SkPPWGuNA/CE8CpyANIhu9XFrj3RQ3EqeRcSAQQod1RNuHpfETLU/A2gMmvn/w/sx7TB3W5BPs6rprOA37tutPq9u6FTZOcG1OqjC/B7yTqgI7rbyvox7DEXoX7rIiEqyNNUguTk/u3SZ4VXE2kmxdmSh3TQvybfbnXV4JbCZVaqiZraqc7oZMnRoWrXRG3ztbnbes/9qhRGI7PqXqeKJBztxRTEVj8ONs1dWN5szTwaPIvhkhO3CO5ErU2rVdUr89wKpNXbBODFKRtgxUT70YpmJ46VVaqdAhOZD9EUUn4YaeLaS8AjSF/h7UkjOibNc4qVDiPP+rkehFWM66PVnP1Msh93tc+taIfCEYVMxjh8zNbFuoc7fzvvrFILLe7ifvEIUqSVIC/AzplM/Jxw7buXFeGP1qVCBEHq391d/9RAfaZ12zkwFsl+IKwE/OZxW8AHa9i1p4GO0YSNuczzEm4="

    /// Shared anchors so both URLSession and WKWebView trust handling reuse them.
    static let sharedAnchors: [SecCertificate] = SberTrustDelegate.loadAnchors()

    override init() {
        anchors = SberTrustDelegate.sharedAnchors
        super.init()
        slog.notice("Sber trust: loaded \(self.anchors.count, privacy: .public) anchor cert(s)")
    }

    /// Evaluate a server-trust challenge for Sber hosts (Russian Trusted CA) —
    /// reusable by URLSession and WKWebView. Two stages: system trust first
    /// (Let's Encrypt hosts), then our Russian root only.
    static func resolve(_ challenge: URLAuthenticationChallenge)
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        let host = challenge.protectionSpace.host
        guard host.hasSuffix("sberbank.ru") || host.hasSuffix("sberdevices.ru") else {
            return (.performDefaultHandling, nil)
        }
        var err1: CFError?
        if SecTrustEvaluateWithError(trust, &err1) {
            SberTrustDiag.shared.set("trust \(host): OK (system)")
            return (.useCredential, URLCredential(trust: trust))
        }
        SecTrustSetAnchorCertificates(trust, sharedAnchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var err2: CFError?
        if SecTrustEvaluateWithError(trust, &err2) {
            SberTrustDiag.shared.set("trust \(host): OK (russian root)")
            return (.useCredential, URLCredential(trust: trust))
        }
        let e1 = (err1.map { CFErrorCopyDescription($0) as String }) ?? "?"
        let e2 = (err2.map { CFErrorCopyDescription($0) as String }) ?? "?"
        SberTrustDiag.shared.set("trust \(host): FAIL system=\(e1) russian=\(e2)")
        return (.cancelAuthenticationChallenge, nil)
    }

    private static func loadAnchors() -> [SecCertificate] {
        if let der = Data(base64Encoded: rootCADER),
           let cert = SecCertificateCreateWithData(nil, der as CFData) {
            return [cert]
        }
        slog.error("Sber trust: embedded CA failed to parse")
        return []
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (disposition, credential) = SberTrustDelegate.resolve(challenge)
        completionHandler(disposition, credential)
    }
}

/// One in-app Sber login attempt: the authorize URL to load and the PKCE verifier
/// to redeem the returned code with.
struct SberAuthSession {
    let url: URL
    let verifier: String
    let state: String
}

/// base64url without padding (for PKCE code_challenge).
private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// Random string from the PKCE unreserved set.
private func randomURLSafe(_ count: Int) -> String {
    let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    var out = ""
    out.reserveCapacity(count)
    for _ in 0..<count { out.append(chars[Int.random(in: 0..<chars.count)]) }
    return out
}

actor SberCloudClient {
    static let shared = SberCloudClient()

    private let session: URLSession
    private var token: SberToken?

    private static let keychainKey = "sber.token.v1"

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        session = URLSession(configuration: cfg, delegate: SberTrustDelegate(), delegateQueue: nil)
        token = SberCloudClient.loadToken()
    }

    var hasToken: Bool { token != nil }

    /// Import a token pasted by the user (the JSON object from HA's config entry
    /// `data.token`, or any object with access_token / refresh_token).
    func importToken(json: String) throws {
        guard let data = json.data(using: .utf8) else { throw SberError.badResponse }
        let tok = try JSONDecoder().decode(SberToken.self, from: data)
        token = tok
        SberCloudClient.saveToken(tok)
        slog.notice("Sber token imported (expires \(tok.expiresAt.map { String($0) } ?? "n/a", privacy: .public))")
    }

    func clearToken() { token = nil; SberCloudClient.deleteToken() }

    // MARK: - OAuth login (Authorization Code + PKCE)

    /// Build the Sber authorize URL + PKCE verifier for an in-app login. Pure, so
    /// the UI can call it without awaiting the actor.
    nonisolated static func makeAuthSession() -> SberAuthSession {
        let verifier = randomURLSafe(64)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomURLSafe(16)
        var c = URLComponents(string: SberAPI.authEndpoint)!
        c.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: SberAPI.clientID),
            .init(name: "redirect_uri", value: SberAPI.redirectURI),
            .init(name: "scope", value: "openid"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "nonce", value: randomURLSafe(16)),
        ]
        return SberAuthSession(url: c.url!, verifier: verifier, state: state)
    }

    /// Exchange the authorization `code` (from the companionapp://host redirect)
    /// for tokens and store them.
    func completeLogin(code: String, verifier: String) async throws {
        var req = URLRequest(url: URL(string: SberAPI.tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(SberAPI.userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = SberCloudClient.formEncode([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", SberAPI.redirectURI),
            ("client_id", SberAPI.clientID),
            ("code_verifier", verifier),
        ]).data(using: .utf8)
        let (data, status) = try await send("oauth token exchange", req)
        guard (200...299).contains(status) else {
            throw SberError.refreshFailed("HTTP \(status): \(String(decoding: data, as: UTF8.self).prefix(160))")
        }
        let tok = try JSONDecoder().decode(SberToken.self, from: data)
        token = tok
        SberCloudClient.saveToken(tok)
        slog.notice("Sber token obtained via in-app login")
    }

    private static func formEncode(_ pairs: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return pairs.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }

    // MARK: - Public control

    /// Set the relay explicitly on/off.
    func setRelay(deviceID: String = SberAPI.defaultDeviceID, on: Bool) async throws {
        let gw = try await gatewayToken()
        try await putState(deviceID: deviceID, on: on, gatewayJWT: gw)
        slog.notice("Sber set relay \(deviceID, privacy: .public) -> \(on, privacy: .public)")
    }

    /// Toggle: read current on_off, invert, set. Returns the new state.
    @discardableResult
    func toggleRelay(deviceID: String = SberAPI.defaultDeviceID) async throws -> Bool {
        let gw = try await gatewayToken()
        let current = try await currentOnOff(deviceID: deviceID, gatewayJWT: gw)
        try await putState(deviceID: deviceID, on: !current, gatewayJWT: gw)
        slog.notice("Sber toggle \(deviceID, privacy: .public) \(current, privacy: .public)->\(!current, privacy: .public)")
        return !current
    }

    /// Apply an action string ("on"/"off"/"toggle").
    func apply(action: String, deviceID: String = SberAPI.defaultDeviceID) async throws {
        switch action {
        case "on":     try await setRelay(deviceID: deviceID, on: true)
        case "off":    try await setRelay(deviceID: deviceID, on: false)
        case "toggle": _ = try await toggleRelay(deviceID: deviceID)
        default:       throw SberError.badResponse
        }
    }

    // MARK: - Networking

    /// Tags transport errors (TLS, timeouts) with the step that failed so the
    /// Activity log shows exactly where the chain broke.
    private func send(_ step: String, _ req: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, resp) = try await session.data(for: req)
            return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let e as SberError {
            throw e
        } catch {
            throw SberError.step(step, error.localizedDescription)
        }
    }

    // MARK: - OAuth

    private func validAccessToken(force: Bool = false) async throws -> String {
        guard var tok = token else { throw SberError.noToken }
        if (force || tok.isExpired), !tok.refreshToken.isEmpty {
            tok = try await refresh(tok)
            token = tok
            SberCloudClient.saveToken(tok)
        }
        return tok.accessToken
    }

    private func refresh(_ tok: SberToken) async throws -> SberToken {
        var req = URLRequest(url: URL(string: SberAPI.tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=refresh_token&refresh_token=\(tok.refreshToken)&client_id=\(SberAPI.clientID)"
        req.httpBody = body.data(using: .utf8)
        let (data, code) = try await send("refresh online.sberbank.ru:4431", req)
        guard (200...299).contains(code) else {
            throw SberError.refreshFailed("HTTP \(code): \(String(decoding: data, as: UTF8.self).prefix(120))")
        }
        var fresh = try JSONDecoder().decode(SberToken.self, from: data)
        if fresh.refreshToken.isEmpty { fresh.refreshToken = tok.refreshToken } // some servers omit it
        return fresh
    }

    /// Exchange the OAuth access token for a gateway JWT (X-AUTH-jwt).
    /// On a 401 (access token superseded/expired) refresh once and retry.
    private func gatewayToken(force: Bool = false) async throws -> String {
        let access = try await validAccessToken(force: force)
        var req = URLRequest(url: URL(string: SberAPI.companionToken)!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        req.setValue(SberAPI.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, code) = try await send("companion-token", req)
        if code == 401, !force {
            slog.notice("Sber companion 401 → refresh + retry")
            return try await gatewayToken(force: true)
        }
        guard (200...299).contains(code) else {
            throw SberError.http(code, String(decoding: data, as: UTF8.self))
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jwt = obj["token"] as? String else { throw SberError.badResponse }
        return jwt
    }

    // MARK: - Gateway

    private func putState(deviceID: String, on: Bool, gatewayJWT: String) async throws {
        var req = URLRequest(url: URL(string: "\(SberAPI.gatewayBase)/devices/\(deviceID)/state")!)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(gatewayJWT, forHTTPHeaderField: "X-AUTH-jwt")
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(identifier: "UTC")
        let body: [String: Any] = [
            "device_id": deviceID,
            "desired_state": [["key": "on_off", "bool_value": on]],
            "timestamp": iso.string(from: Date())
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, code) = try await send("putState gateway", req)
        guard (200...299).contains(code) else {
            throw SberError.http(code, String(decoding: data, as: UTF8.self))
        }
    }

    private func currentOnOff(deviceID: String, gatewayJWT: String) async throws -> Bool {
        var req = URLRequest(url: URL(string: "\(SberAPI.gatewayBase)/device_groups/tree")!)
        req.setValue(gatewayJWT, forHTTPHeaderField: "X-AUTH-jwt")
        let (data, code) = try await send("tree gateway", req)
        guard (200...299).contains(code) else { throw SberError.http(code, String(decoding: data, as: UTF8.self)) }
        // Walk the tree to find the device and its reported on_off.
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SberError.badResponse
        }
        if let val = Self.findOnOff(in: root, deviceID: deviceID) { return val }
        throw SberError.badResponse
    }

    private static func findOnOff(in node: Any, deviceID: String) -> Bool? {
        if let dict = node as? [String: Any] {
            if (dict["id"] as? String) == deviceID,
               let reported = dict["reported_state"] as? [[String: Any]],
               let onoff = reported.first(where: { ($0["key"] as? String) == "on_off" }) {
                return onoff["bool_value"] as? Bool
            }
            for (_, v) in dict { if let r = findOnOff(in: v, deviceID: deviceID) { return r } }
        } else if let arr = node as? [Any] {
            for v in arr { if let r = findOnOff(in: v, deviceID: deviceID) { return r } }
        }
        return nil
    }

    // MARK: - Keychain

    private static func saveToken(_ tok: SberToken) {
        guard let data = try? JSONEncoder().encode(tok) else { return }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: keychainKey]
        SecItemDelete(q as CFDictionary)
        var add = q; add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func loadToken() -> SberToken? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: keychainKey,
                                kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(SberToken.self, from: data)
    }

    private static func deleteToken() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: keychainKey]
        SecItemDelete(q as CFDictionary)
    }
}
