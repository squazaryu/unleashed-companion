import Foundation
import CoreBluetooth
import Combine
import os

private let blelog = Logger(subsystem: "com.tumoflip.unleashedcompanion", category: "ble")

/// BLE UUIDs derived directly from the tumoflip / Unleashed firmware
/// (`targets/f7/ble_glue/services/*_uuid.inc`). Byte arrays there are
/// little-endian; these strings are the big-endian CoreBluetooth form.
enum FlipperUUID {
    // Serial RPC service (protobuf over a Nordic-UART-style pipe)
    static let serialService = CBUUID(string: "8FE5B3D5-2E7F-4A98-2A48-7ACC60FE0000")
    static let serialTx       = CBUUID(string: "19ED82AE-ED21-4C9D-4145-228E61FE0000") // notify  (Flipper -> phone)
    static let serialRx       = CBUUID(string: "19ED82AE-ED21-4C9D-4145-228E62FE0000") // write   (phone -> Flipper)
    static let serialFlow     = CBUUID(string: "19ED82AE-ED21-4C9D-4145-228E63FE0000")
    static let serialStatus   = CBUUID(string: "19ED82AE-ED21-4C9D-4145-228E64FE0000")

    // Custom App Bridge service (tumoflip-only addition)
    static let appBridgeService  = CBUUID(string: "7F7D0000-2E31-4C42-8A98-9B2F6B8C0001")
    static let appBridgeEvents   = CBUUID(string: "7F7D0000-2E31-4C42-8A98-9B2F6B8C0002") // notify (Flipper -> phone)
    static let appBridgeCommands = CBUUID(string: "7F7D0000-2E31-4C42-8A98-9B2F6B8C0003") // write  (phone -> Flipper)

    // Standard BLE Battery Service (Flipper exposes it via ble_svc_battery).
    static let batteryService = CBUUID(string: "180F")
    static let batteryLevel   = CBUUID(string: "2A19") // notify + read, 1 byte 0–100
}

enum FlipperConnectionState: Equatable {
    case poweredOff
    case unauthorized
    case disconnected
    case scanning
    case connecting
    case connected
    case ready          // services + characteristics discovered, RPC usable
}

struct DiscoveredFlipper: Identifiable, Equatable {
    let id: UUID            // CBPeripheral.identifier
    var name: String
    var rssi: Int
    var hasAppBridge: Bool
}

/// Low-level CoreBluetooth transport. Owns the central manager, exposes a raw
/// byte stream for the serial (RPC) pipe and a separate channel for the custom
/// App Bridge service. Higher layers (RPC session, storage) sit on top.
final class FlipperBLE: NSObject, ObservableObject {
    static let shared = FlipperBLE()

    @Published private(set) var state: FlipperConnectionState = .disconnected

    /// When true, the Claude Buddy app on the Flipper owns the serial channel
    /// (raw newline-JSON), so RPC MUST stay off it — any RPC frame interleaved
    /// with Buddy JSON shows as garbage (Cyrillic glyphs) and crashes the .fap
    /// (furi_check). BuddyRelay sets this while passthrough is active.
    var buddyMode = false
    @Published private(set) var discovered: [DiscoveredFlipper] = []
    @Published private(set) var connectedName: String?
    @Published private(set) var supportsAppBridge = false

    /// Raw bytes arriving on the serial TX characteristic (RPC stream).
    let serialIn = PassthroughSubject<Data, Never>()
    /// Decoded App Bridge events (app_id, command, payload) coming from Flipper.
    let appBridgeIn = PassthroughSubject<AppBridgeFrame, Never>()
    /// True once the firmware answers our FAB2 probe (it spoke FAB2 back). Until
    /// then we use the backward-compatible FAB1 framing. Re-probed every connect.
    /// @Published so the Settings screen can show the negotiated version live.
    @Published private(set) var appBridgeV2 = false
    /// FAB2 request/response correlation (chunk reassembly, timeouts, IDs). Writes
    /// outgoing frames straight to the bridge command characteristic.
    private(set) lazy var appBridge = AppBridgeRequestCoordinator(send: { [weak self] frames in
        self?.writeBridgeFrames(frames)
    })
    /// Capabilities reported by the firmware's `runtime/capabilities` response. All
    /// keys are preserved, including ones this client doesn't recognise.
    @Published private(set) var appBridgeCapabilities: [String: String] = [:]
    /// Flipper battery level 0–100 from the standard BLE Battery Service (notify).
    @Published private(set) var battery: Int?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxChar: CBCharacteristic?      // write to Flipper (RPC)
    private var txChar: CBCharacteristic?      // notify from Flipper (RPC)
    private var bridgeCmdChar: CBCharacteristic?
    private var bridgeEvtChar: CBCharacteristic?

    private var wantsConnectID: UUID?
    private var userInitiatedDisconnect = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5

    /// Keep the BLE link alive in the background: a timeout-less standing connect that
    /// iOS holds across suspension / app relaunch, with unbounded reconnect, so Flipper
    /// Relay events still reach the phone while the app is backgrounded. (Can't survive
    /// a user force-quit — that's an iOS limit.)
    private static let keepAliveKey = "ble.keepAlive"
    @Published var keepAlive: Bool = (UserDefaults.standard.object(forKey: FlipperBLE.keepAliveKey) as? Bool ?? true) {
        didSet {
            UserDefaults.standard.set(keepAlive, forKey: Self.keepAliveKey)
            if keepAlive, state == .disconnected { autoConnect() }
        }
    }
    private let queue = DispatchQueue(label: "flipper.ble")
    private var pendingRestore: CBPeripheral?    // adopted in willRestoreState
    private var connectGen = 0                   // invalidates stale connect watchdogs
    // Ready watchdog (issue #10): bounds the "link connected but never reaches .ready"
    // case — a stale restored link or stuck characteristic discovery. Runs even when
    // keepAlive suppresses the connect watchdog above, so the app can't sit in
    // Connecting forever while the Flipper holds the link and stops advertising.
    private var readyGen = 0
    private let readyTimeout: TimeInterval = 12
    private var connectStartedAt: Date?

    private override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue, options: [
            CBCentralManagerOptionShowPowerAlertKey: true,
            // Preserve the connection across app relaunch so a Flipper that's still
            // showing "connected" can be reclaimed instead of left half-open
            // (which blocks a fresh connect until you toggle its Bluetooth).
            CBCentralManagerOptionRestoreIdentifierKey: "com.tumoflip.unleashed.central"
        ])
    }

    // MARK: - Public API

    /// Wait up to `timeout` seconds for the link to reach `.ready`. Returns true
    /// once ready, false on timeout. This tolerates the brief `.connected →
    /// .ready` service-discovery gap and short auto-reconnect blips, so a command
    /// fired right after the UI shows "connected" doesn't fail with notReady.
    func waitUntilReady(timeout: TimeInterval = 6) async -> Bool {
        if state == .ready { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // No connection in progress and nothing to reconnect to → give up early.
            if state == .disconnected && wantsConnectID == nil { return false }
            if state == .poweredOff || state == .unauthorized { return false }
            try? await Task.sleep(nanoseconds: 120_000_000)
            if state == .ready { return true }
        }
        return state == .ready
    }

    private let lastDeviceKey = "lastFlipperID"

    /// Smart connect for app-launch / foreground. A Flipper STOPS advertising
    /// while it's connected, so a plain scan can't rediscover one the system is
    /// already holding a link to (the classic "rescan finds nothing until I
    /// toggle BLE on the Flipper" trap). So we reattach to a retained connection
    /// first, fall back to the last known device, and only scan as a last resort.
    func autoConnect() {
        guard central.state == .poweredOn else { return }
        if state == .ready || state == .connected { return }
        // A connect attempt that's still fresh is left to run (its ready watchdog will
        // recover it). But don't early-return forever on a .connecting that has gone
        // stale past the ready timeout — fall through to force a clean fresh attempt.
        if state == .connecting,
           let started = connectStartedAt, Date().timeIntervalSince(started) <= readyTimeout { return }

        // 1. A connection the OS still holds (Flipper isn't advertising while
        //    connected, so a scan can't find it).
        if let p = central.retrieveConnectedPeripherals(withServices: [FlipperUUID.serialService]).first {
            adoptHeld(p)
            return
        }
        // 2. Last known device — retrievable by id without advertising.
        if let idStr = UserDefaults.standard.string(forKey: lastDeviceKey),
           let id = UUID(uuidString: idStr),
           let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            blelog.notice("reconnecting to last known Flipper")
            wantsConnectID = id
            userInitiatedDisconnect = false
            reconnectAttempts = 0
            beginConnect(p)
            return
        }
        // 3. Nothing retained — scan.
        startScan()
    }

    func startScan() {
        guard central.state == .poweredOn else { return }
        // Even when the user asks to scan, grab an already-connected Flipper first
        // (it won't show up in a scan because it isn't advertising).
        if let p = central.retrieveConnectedPeripherals(withServices: [FlipperUUID.serialService]).first {
            adoptHeld(p)
            return
        }
        DispatchQueue.main.async { self.discovered = []; self.state = .scanning }
        central.scanForPeripherals(withServices: [FlipperUUID.serialService], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
        // Some Flippers don't advertise the 128-bit service; also do a name scan.
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    func stopScan() {
        central.stopScan()
        // Reset the state so the UI leaves "scanning" (the stop button flips back).
        DispatchQueue.main.async {
            if self.state == .scanning { self.state = .disconnected }
        }
    }

    func connect(_ id: UUID) {
        stopScan()
        wantsConnectID = id
        userInitiatedDisconnect = false
        reconnectAttempts = 0
        if let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            beginConnect(p)
        } else {
            // Not cached — scan for it and connect on discovery.
            blelog.notice("peripheral not cached, scanning to reconnect")
            DispatchQueue.main.async { self.state = .connecting }
            central.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    func disconnect() {
        userInitiatedDisconnect = true
        wantsConnectID = nil
        readyGen &+= 1   // disarm any pending ready watchdog
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    // Flow-controlled TX pipeline — matches how qFlipper / the official Flipper
    // app write over BLE. The Flipper's serial service exposes an RX-buffer credit
    // on its flow-control characteristic (big-endian u32, RPC_BUFFER_SIZE = 1024)
    // and RE-NOTIFIES the full credit every time its RPC buffer drains to empty.
    // The client MUST NOT send more than the current credit, and each ATT write
    // must be <= BLE_SVC_SERIAL_DATA_LEN_MAX (486). Writes go .withoutResponse,
    // gated by canSendWriteWithoutResponse. Ignoring this is exactly what overran
    // the Flipper and wedged the link mid-upload — the bug the official app avoids.
    private struct TxItem { let data: Data; let done: (() -> Void)? }
    private var txItems: [TxItem] = []
    private var txOffset = 0
    private var txCredit = 0
    private var txGen = 0
    private let serialDataLenMax = 486    // BLE_SVC_SERIAL_DATA_LEN_MAX
    private let serialRxBuffer = 1024     // RPC_BUFFER_SIZE — initial/refilled credit
    private let txStallTimeout: TimeInterval = 8

    /// Queue RPC bytes for the Flipper. `completion` fires once all of this call's
    /// bytes have been handed to the link within the Flipper's flow-control credit
    /// (or immediately if the link is gone), so callers can pace + show progress.
    func writeSerial(_ data: Data, completion: (() -> Void)? = nil) {
        guard peripheral != nil, rxChar != nil, !data.isEmpty else { completion?(); return }
        queue.async {
            self.txItems.append(TxItem(data: data, done: completion))
            self.pumpTx()
        }
    }

    /// Drain the TX queue while we have flow-control credit and the link can take
    /// a write-without-response. Runs on `queue`.
    private func pumpTx() {
        guard let p = peripheral, let rx = rxChar else { return }
        while let head = txItems.first {
            if txOffset >= head.data.count {        // current item fully sent
                txItems.removeFirst(); txOffset = 0
                head.done?()
                continue
            }
            guard txCredit > 0 else { armTxWatchdog(); return }   // wait for refill
            guard p.canSendWriteWithoutResponse else { return }   // wait for ready
            let cbMax = max(20, p.maximumWriteValueLength(for: .withoutResponse))
            let n = min(head.data.count - txOffset, serialDataLenMax, txCredit, cbMax)
            let chunk = head.data.subdata(in: txOffset ..< txOffset + n)
            p.writeValue(chunk, for: rx, type: .withoutResponse)
            txOffset += n
            txCredit -= n
            txGen &+= 1
        }
    }

    /// Apply a flow-control credit update (the Flipper notified its buffer is free
    /// again). Always a full reset to the notified value — safe because the Flipper
    /// only notifies when its RX buffer is empty.
    private func setTxCredit(_ credit: Int) {
        txCredit = credit
        txGen &+= 1
        pumpTx()
    }

    /// If we're blocked with pending data and no credit for too long, the link is
    /// wedged — force a disconnect so iOS notices and reattach/reconnect kicks in.
    private func armTxWatchdog() {
        let gen = txGen
        queue.asyncAfter(deadline: .now() + txStallTimeout) { [weak self] in
            guard let self = self, self.txGen == gen,
                  !self.txItems.isEmpty, self.txCredit <= 0 else { return }
            blelog.error("serial TX stalled (no flow-control credit) — forcing reconnect")
            if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
        }
    }

    /// Drop the TX queue and resume any waiters (called on disconnect so a pending
    /// upload doesn't hang forever).
    private func flushTxQueue() {
        let items = txItems
        txItems.removeAll(); txOffset = 0; txCredit = 0
        for it in items { it.done?() }
        rawItems.removeAll(); rawOffset = 0
    }

    // Credit-free raw serial writer for Claude Buddy passthrough. The Buddy .fap
    // takes over the serial callback and does NOT feed the RPC buffer, so the
    // firmware never refills the RPC flow-control credit — meaning the credit-gated
    // writeSerial above would stall and trip its stall-watchdog into a forced
    // reconnect (the "periodically disconnects" bug). Mirror the plugin's own
    // host-bridge: just write MTU-sized chunks .withoutResponse, paced only by
    // CoreBluetooth's local queue (canSendWriteWithoutResponse). Payloads are tiny.
    private var rawItems: [Data] = []
    private var rawOffset = 0

    func writeSerialRaw(_ data: Data) {
        guard peripheral != nil, rxChar != nil, !data.isEmpty else { return }
        queue.async { self.rawItems.append(data); self.pumpRaw() }
    }

    private func pumpRaw() {
        guard let p = peripheral, let rx = rxChar else { return }
        while let head = rawItems.first {
            if rawOffset >= head.count { rawItems.removeFirst(); rawOffset = 0; continue }
            guard p.canSendWriteWithoutResponse else { return }   // paced by peripheralIsReady
            let cbMax = max(20, p.maximumWriteValueLength(for: .withoutResponse))
            let n = min(head.count - rawOffset, serialDataLenMax, cbMax)
            let chunk = head.subdata(in: rawOffset ..< rawOffset + n)
            p.writeValue(chunk, for: rx, type: .withoutResponse)
            rawOffset += n
        }
    }

    private static func parseFlowControl(_ data: Data) -> Int? {
        guard data.count == 4 else { return nil }
        // Wire format is big-endian (firmware REVERSE_BYTES_U32 before notifying).
        return data.reduce(0) { ($0 << 8) | Int($1) }
    }

    /// Write already-encoded App Bridge frames to the command characteristic.
    private func writeBridgeFrames(_ frames: [Data]) {
        guard let p = peripheral, let c = bridgeCmdChar else { return }
        for f in frames { p.writeValue(f, for: c, type: .withResponse) }
    }

    /// Send a custom App Bridge command frame to the Flipper, fire-and-forget. Uses
    /// FAB2 (chunked, with a request id) once negotiated, otherwise the legacy FAB1
    /// frame. This is the event-driven path used by Relay / AI Radar.
    func sendAppBridge(appID: String, command: String, payload: Data = Data()) {
        guard let p = peripheral, let c = bridgeCmdChar else { return }
        if appBridgeV2 {
            let id = appBridge.reserveID()
            guard let frames = AppBridgeFrame.encodeV2(
                appID: appID, command: command, payload: payload, requestID: id) else { return }
            for f in frames { p.writeValue(f, for: c, type: .withResponse) }
        } else {
            guard let frame = AppBridgeFrame(appID: appID, command: command, payload: payload).encoded() else { return }
            p.writeValue(frame, for: c, type: .withResponse)
        }
    }

    /// Send a FAB2 request and await the firmware's correlated response payload.
    /// Requires a v2-negotiated link; throws `AppBridgeError.notNegotiated` otherwise.
    func appBridgeRequest(appID: String, command: String, payload: Data = Data(),
                          timeout: TimeInterval = 5) async throws -> Data {
        guard appBridgeV2 else { throw AppBridgeError.notNegotiated }
        guard peripheral != nil, bridgeCmdChar != nil else { throw AppBridgeError.disconnected }
        return try await appBridge.request(appID: appID, command: command,
                                           payload: payload, timeout: timeout)
    }

    /// Probe FAB2 support: send `runtime/capabilities` and wait for the *matching*
    /// correlated response. Only a real response negotiates v2 — a stray FAB2 event
    /// can no longer flip the flag. A FAB1-only firmware never answers, so the probe
    /// times out and we stay on FAB1. Safe to call on every connect.
    private func probeAppBridgeV2() {
        guard peripheral != nil, bridgeCmdChar != nil else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let payload = try await self.appBridge.request(
                    appID: "runtime", command: "capabilities", payload: Data(), timeout: 3)
                let caps = Self.parseCapabilities(payload)
                // Negotiate v2 ONLY on a correct capabilities response: runtime=1 and
                // fab=2. A response with empty/garbage caps must NOT flip the flag.
                guard caps["runtime"] == "1", caps["fab"] == "2" else {
                    blelog.notice("App Bridge probe: response lacked runtime=1/fab=2 — staying on FAB1")
                    return
                }
                await MainActor.run {
                    self.appBridgeCapabilities = caps
                    self.appBridgeV2 = true
                    blelog.notice("App Bridge v2 negotiated (\(caps.count, privacy: .public) caps)")
                }
            } catch {
                blelog.notice("App Bridge v2 probe failed (\(error.localizedDescription, privacy: .public)) — staying on FAB1")
            }
        }
    }

    /// Parse a `runtime/capabilities` payload into a flat string map, preserving every
    /// key (including ones we don't recognise). The tumoflip firmware sends a
    /// semicolon-separated `key=value` payload, e.g.
    /// `runtime=1;fab=2;packages=2;legacy=1;payload=160;...`. JSON is kept only as a
    /// backward-compatible fallback.
    static func parseCapabilities(_ data: Data) -> [String: String] {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return [:] }
        if text.contains("=") {
            var out: [String: String] = [:]
            for pair in text.split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard kv.count == 2 else { continue }
                let k = kv[0].trimmingCharacters(in: .whitespaces)
                let v = kv[1].trimmingCharacters(in: .whitespaces)
                if !k.isEmpty { out[k] = v }
            }
            if !out.isEmpty { return out }
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var out: [String: String] = [:]
            for (k, v) in obj { out[k] = String(describing: v) }
            return out
        }
        return [:]
    }

    /// Adopt a connection the system is still holding. If it's a leftover from a
    /// previous app process (we have no peripheral of our own yet), the Flipper's
    /// RPC session is dead — reattaching gives a "connected" link that doesn't work
    /// (the "bridge stays up but won't reconnect until I toggle Flipper BLE" bug).
    /// Force a clean disconnect so the Flipper resets, then reconnect fresh.
    private func adoptHeld(_ p: CBPeripheral) {
        wantsConnectID = p.identifier
        userInitiatedDisconnect = false
        reconnectAttempts = 0
        if peripheral == nil {
            blelog.notice("clearing stale held Flipper link — reconnecting fresh")
            peripheral = p
            p.delegate = self
            DispatchQueue.main.async { self.state = .connecting }
            connectStartedAt = Date()
            armReadyWatchdog(for: p)   // recover even if the cancel below never yields didDisconnect
            central.cancelPeripheralConnection(p)   // → didDisconnect → fresh reconnect
        } else {
            beginConnect(p)
        }
    }

    private func beginConnect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        DispatchQueue.main.async { self.state = .connecting }
        connectStartedAt = Date()
        central.connect(p, options: nil)
        // Always arm the ready watchdog — including under keepAlive — so a link that
        // connects but never reaches app-level .ready gets a bounded clean reconnect.
        armReadyWatchdog(for: p)
        // Keep-alive: leave the connect pending with no timeout. CoreBluetooth holds a
        // standing "connect when available" request across suspension / app relaunch and
        // reconnects the Flipper the moment it's back in range — that's what keeps the
        // bridge (and Relay events) working while the app is backgrounded.
        guard !keepAlive else { return }
        // Watchdog: if the connect never completes, the Flipper is likely holding a
        // stale half-open link and not advertising. Cancel so we don't hang forever.
        connectGen &+= 1
        let gen = connectGen
        queue.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self = self, self.connectGen == gen,
                  self.peripheral?.state != .connected else { return }
            blelog.error("connect timed out — cancelling (Flipper may be half-open)")
            if let per = self.peripheral { self.central.cancelPeripheralConnection(per) }
            DispatchQueue.main.async { if self.state == .connecting { self.state = .disconnected } }
        }
    }

    /// Bounds the "connected (or restored) but never .ready" stall (issue #10). Fires if
    /// the serial characteristics aren't discovered within `readyTimeout`: drops stale
    /// GATT state and cancels the link so iOS releases it and the Flipper advertises
    /// again. `didDisconnect`'s keep-alive path then reconnects fresh (and re-arms a new
    /// watchdog, bumping `readyGen`); the delayed block here is a fallback that only runs
    /// if nothing re-armed in the meantime.
    func armReadyWatchdog(for p: CBPeripheral) {
        readyGen &+= 1
        let gen = readyGen
        queue.asyncAfter(deadline: .now() + readyTimeout) { [weak self, weak p] in
            guard let self = self, let p = p else { return }
            guard self.readyGen == gen else { return }                       // reached .ready or superseded
            guard self.state == .connecting || self.state == .connected else { return }
            guard self.rxChar == nil || self.txChar == nil else { return }   // serial chars up → usable
            guard !self.userInitiatedDisconnect else { return }
            blelog.error("BLE ready timed out — forcing clean reconnect")
            self.clearDiscoveredCharacteristics()
            self.central.cancelPeripheralConnection(p)   // → didDisconnect → keep-alive reconnect re-arms
            self.queue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self = self else { return }
                guard self.readyGen == gen else { return }   // didDisconnect already reconnected → done
                guard !self.userInitiatedDisconnect else { return }
                if let want = self.wantsConnectID,
                   let retry = self.central.retrievePeripherals(withIdentifiers: [want]).first {
                    self.beginConnect(retry)
                } else {
                    DispatchQueue.main.async { self.state = .disconnected }
                    self.autoConnect()
                }
            }
        }
    }

    /// Drop every reference that may hold a stale GATT handle before a clean reconnect.
    /// Queue-confined fields are cleared here; published ones hop to main.
    private func clearDiscoveredCharacteristics() {
        rxChar = nil; txChar = nil
        bridgeCmdChar = nil; bridgeEvtChar = nil
        flushTxQueue()                    // drops tx/raw queues + resumes waiters
        appBridge.failAll(.disconnected)
        DispatchQueue.main.async {
            self.supportsAppBridge = false
            self.appBridgeV2 = false
            self.appBridgeCapabilities = [:]
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension FlipperBLE: CBCentralManagerDelegate {
    // Called when CoreBluetooth restores our central after an app relaunch. Adopt
    // the preserved peripheral so the still-live connection is reclaimed rather
    // than left half-open on the Flipper.
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let p = restored.first else { return }
        blelog.notice("restoring preserved Flipper connection")
        p.delegate = self
        peripheral = p
        wantsConnectID = p.identifier
        userInitiatedDisconnect = false
        pendingRestore = p
        UserDefaults.standard.set(p.identifier.uuidString, forKey: lastDeviceKey)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn, let p = pendingRestore {
            pendingRestore = nil
            // A restored connection from a previous process has a dead RPC session.
            // Reset it cleanly and reconnect fresh rather than reattaching a link
            // that looks connected but doesn't work.
            wantsConnectID = p.identifier
            userInitiatedDisconnect = false
            reconnectAttempts = 0
            peripheral = p
            p.delegate = self
            DispatchQueue.main.async { self.state = .connecting }
            if p.state == .connected {
                central.cancelPeripheralConnection(p)   // → didDisconnect → fresh reconnect
            } else {
                beginConnect(p)
            }
        }
        DispatchQueue.main.async {
            switch central.state {
            case .poweredOn:    if self.state == .poweredOff { self.state = .disconnected }
            case .poweredOff:   self.state = .poweredOff
            case .unauthorized: self.state = .unauthorized
            default:            self.state = .disconnected
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        guard let name = advName else { return }
        let looksLikeFlipper = name.localizedCaseInsensitiveContains("flipper")
            || name.localizedCaseInsensitiveContains("tumoflip")
            || (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.contains(FlipperUUID.serialService) == true
        guard looksLikeFlipper else { return }

        // Reconnecting to a specific device — grab it and stop scanning.
        if let want = wantsConnectID, peripheral.identifier == want {
            beginConnect(peripheral)
            return
        }

        let entry = DiscoveredFlipper(id: peripheral.identifier, name: name,
                                      rssi: RSSI.intValue, hasAppBridge: false)
        DispatchQueue.main.async {
            if let i = self.discovered.firstIndex(where: { $0.id == entry.id }) {
                self.discovered[i].rssi = entry.rssi
                self.discovered[i].name = entry.name
            } else {
                self.discovered.append(entry)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        reconnectAttempts = 0
        stopScan()
        // Remember it so we can reattach across app launches without a scan.
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: lastDeviceKey)
        DispatchQueue.main.async {
            self.state = .connected
            self.connectedName = peripheral.name
        }
        peripheral.discoverServices([FlipperUUID.serialService, FlipperUUID.appBridgeService, FlipperUUID.batteryService])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        flushTxQueue()   // resume any in-flight upload waiters
        appBridge.failAll(.disconnected)   // fail any pending FAB2 requests once
        // Auto-reconnect on an unexpected drop (out of range, Flipper slept, etc.).
        // Keep-alive reconnects forever; otherwise we give up after maxReconnectAttempts.
        if !userInitiatedDisconnect, let want = wantsConnectID,
           keepAlive || reconnectAttempts < maxReconnectAttempts {
            reconnectAttempts += 1
            blelog.notice("unexpected disconnect, reconnect attempt \(self.reconnectAttempts)\(self.keepAlive ? " (keep-alive)" : "")")
            DispatchQueue.main.async {
                self.state = .connecting
                self.supportsAppBridge = false
                self.rxChar = nil; self.txChar = nil
                self.bridgeCmdChar = nil; self.bridgeEvtChar = nil
            }
            if let p = central.retrievePeripherals(withIdentifiers: [want]).first {
                // Keep-alive: reissue the standing connect immediately while the app is
                // still briefly awake from this disconnect, so iOS holds it across the
                // next suspension. Otherwise back off 1s between bounded attempts.
                if keepAlive {
                    beginConnect(p)
                } else {
                    queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.beginConnect(p) }
                }
            } else {
                central.scanForPeripherals(withServices: nil, options: nil)
            }
            return
        }
        DispatchQueue.main.async {
            self.state = .disconnected
            self.connectedName = nil
            self.supportsAppBridge = false
            self.rxChar = nil; self.txChar = nil
            self.bridgeCmdChar = nil; self.bridgeEvtChar = nil
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        DispatchQueue.main.async { self.state = .disconnected }
    }
}

// MARK: - CBPeripheralDelegate
extension FlipperBLE: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            switch service.uuid {
            case FlipperUUID.serialService:
                peripheral.discoverCharacteristics(
                    [FlipperUUID.serialRx, FlipperUUID.serialTx,
                     FlipperUUID.serialFlow, FlipperUUID.serialStatus], for: service)
            case FlipperUUID.appBridgeService:
                DispatchQueue.main.async { self.supportsAppBridge = true }
                peripheral.discoverCharacteristics(
                    [FlipperUUID.appBridgeCommands, FlipperUUID.appBridgeEvents], for: service)
            case FlipperUUID.batteryService:
                peripheral.discoverCharacteristics([FlipperUUID.batteryLevel], for: service)
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case FlipperUUID.serialTx:
                txChar = c
                peripheral.setNotifyValue(true, for: c)
            case FlipperUUID.serialRx:
                rxChar = c
            case FlipperUUID.serialFlow:
                // Subscribe to flow-control credit updates (buffer-empty refills).
                peripheral.setNotifyValue(true, for: c)
            case FlipperUUID.appBridgeEvents:
                bridgeEvtChar = c
                peripheral.setNotifyValue(true, for: c)
            case FlipperUUID.appBridgeCommands:
                bridgeCmdChar = c
            case FlipperUUID.batteryLevel:
                peripheral.setNotifyValue(true, for: c)
                peripheral.readValue(for: c)
            default:
                break
            }
        }
        if rxChar != nil && txChar != nil {
            readyGen &+= 1   // reached app-level readiness → disarm the ready watchdog
            blelog.notice("RPC ready; appBridge=\(self.bridgeEvtChar != nil, privacy: .public)")
            // Buffer starts empty → we may send a full RX buffer before the first
            // flow-control notification. (Don't READ the initial value: it can be
            // stale-high and over-credit us mid-stream.)
            txItems.removeAll(); txOffset = 0; txCredit = serialRxBuffer
            DispatchQueue.main.async { self.appBridgeV2 = false; self.appBridgeCapabilities = [:]; self.state = .ready } // re-negotiate each connect
            if bridgeCmdChar != nil { probeAppBridgeV2() }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case FlipperUUID.serialTx:
            serialIn.send(data)
        case FlipperUUID.serialFlow:
            // Flipper freed its RX buffer → refill our send credit and continue.
            if let credit = Self.parseFlowControl(data) { setTxCredit(credit) }
        case FlipperUUID.batteryLevel:
            if let b = data.first { DispatchQueue.main.async { self.battery = min(100, Int(b)) } }
        case FlipperUUID.appBridgeEvents:
            if let frame = AppBridgeFrame(decoding: data) {
                if frame.version == 2 && frame.isResponse {
                    // Correlated reply to one of our requests (incl. the v2 probe).
                    appBridge.ingest(frame)
                } else {
                    // Unsolicited firmware event → event-driven Relay / AI Radar.
                    DispatchQueue.main.async { self.appBridgeIn.send(frame) }
                }
            }
        default:
            break
        }
    }

    // CoreBluetooth's local write-without-response queue drained — keep sending.
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        pumpTx()
        pumpRaw()
    }
}
