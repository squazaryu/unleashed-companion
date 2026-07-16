@preconcurrency import CoreNFC
import SwiftUI

private final class TumoCardNFCTagHandle: @unchecked Sendable {
    let tag: NFCISO7816Tag

    init(_ tag: NFCISO7816Tag) {
        self.tag = tag
    }
}

final class TumoCardNFCSmokeController: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case scanning
        case running(String)
        case passed(usbHandoff: Bool)
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "Ready"
            case .scanning: return "Scanning"
            case let .running(step): return step
            case .passed: return "Passed"
            case .failed: return "Failed"
            }
        }

        var color: Color {
            switch self {
            case .passed: return .green
            case .failed: return .red
            case .scanning, .running: return .orange
            case .idle: return .secondary
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var steps: [String] = []

    fileprivate struct Response {
        let data: Data
        let status: UInt16
    }

    fileprivate enum SmokeError: LocalizedError {
        case command(String, expected: UInt16, actual: UInt16)
        case transport(String)
        case unexpectedLength(String, Int)
        case stateMismatch(String)
        case invalidCommand

        var errorDescription: String? {
            switch self {
            case let .command(step, expected, actual):
                return "\(step) returned SW=\(String(format: "%04X", actual)); expected \(String(format: "%04X", expected))"
            case let .transport(message): return message
            case let .unexpectedLength(applet, length):
                return "\(applet) returned \(length) bytes"
            case let .stateMismatch(applet): return "\(applet) state verification failed"
            case .invalidCommand: return "Could not build APDU command"
            }
        }
    }

    private var session: NFCTagReaderSession?
    private var counterOriginal = Data()
    private var notesOriginal = Data()
    private var counterDirty = false
    private var notesDirty = false
    private var usbHandoffDetected = false
    private var restoring = false

    var readingAvailable: Bool { NFCTagReaderSession.readingAvailable }

    func start() {
        guard readingAvailable else {
            state = .failed("NFC tag reading is unavailable")
            return
        }
        guard session == nil else { return }

        steps = []
        counterOriginal = Data()
        notesOriginal = Data()
        counterDirty = false
        notesDirty = false
        usbHandoffDetected = false
        restoring = false
        state = .scanning

        guard let session = NFCTagReaderSession(
            pollingOption: [.iso14443],
            delegate: self,
            queue: .main
        ) else {
            state = .failed("Could not create an NFC reader session")
            return
        }
        session.alertMessage = "Hold iPhone near the Flipper running TumoCard OS."
        self.session = session
        session.begin()
    }

    private func append(_ text: String) {
        steps.append(text)
    }

    private func finish(_ state: State, alert: String) {
        self.state = state
        session?.alertMessage = alert
        session?.invalidate()
        session = nil
    }
}

extension TumoCardNFCSmokeController: NFCTagReaderSessionDelegate {
    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(
        _ session: NFCTagReaderSession,
        didInvalidateWithError error: Error
    ) {
        self.session = nil
        let nfcError = error as? NFCReaderError
        guard nfcError?.code != .readerSessionInvalidationErrorUserCanceled else { return }
        if case .passed = state { return }
        state = .failed(error.localizedDescription)
    }

    func tagReaderSession(
        _ session: NFCTagReaderSession,
        didDetect tags: [NFCTag]
    ) {
        guard tags.count == 1, case let .iso7816(tag) = tags[0] else {
            session.alertMessage = tags.count > 1 ? "Present only one NFC target." :
                                                    "TumoCard did not appear as ISO 7816."
            session.restartPolling()
            return
        }
        let tagHandle = TumoCardNFCTagHandle(tag)

        session.connect(to: tags[0]) { [weak self] error in
            guard let self else { return }
            if let error {
                self.finish(.failed(error.localizedDescription), alert: "Connection failed.")
                return
            }
            self.append("ISO 7816 connected")
            self.runSmoke(tagHandle)
        }
    }
}

fileprivate extension TumoCardNFCSmokeController {
    static let counterLength = 8
    static let notesLength = 16
    static let counterMarkerOffset = 5
    static let notesMarkerOffset = 13
    static let usbHandoffMarker = Data([0x66, 0x55, 0xCC])

    func runSmoke(_ tag: TumoCardNFCTagHandle) {
        readOriginals(tag)
    }

    func readOriginals(_ tag: TumoCardNFCTagHandle) {
        select(TumoCardNFCContract.counterAID, name: "Counter", tag: tag) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error): self.fail(error, tag: tag)
            case .success:
                self.read(Self.counterLength, name: "Counter original", tag: tag) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case let .failure(error): self.fail(error, tag: tag)
                    case let .success(data):
                        guard data.count == Self.counterLength else {
                            self.fail(.unexpectedLength("Counter", data.count), tag: tag)
                            return
                        }
                        self.counterOriginal = data
                        self.usbHandoffDetected = data.suffix(Self.usbHandoffMarker.count) == Self.usbHandoffMarker
                        self.readNotesOriginal(tag)
                    }
                }
            }
        }
    }

    func readNotesOriginal(_ tag: TumoCardNFCTagHandle) {
        select(TumoCardNFCContract.notesAID, name: "Notes", tag: tag) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error): self.fail(error, tag: tag)
            case .success:
                self.read(Self.notesLength, name: "Notes original", tag: tag) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case let .failure(error): self.fail(error, tag: tag)
                    case let .success(data):
                        guard data.count == Self.notesLength else {
                            self.fail(.unexpectedLength("Notes", data.count), tag: tag)
                            return
                        }
                        self.notesOriginal = data
                        self.writeCounterMarker(tag)
                    }
                }
            }
        }
    }

    func writeCounterMarker(_ tag: TumoCardNFCTagHandle) {
        select(TumoCardNFCContract.counterAID, name: "Counter", tag: tag) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error): self.fail(error, tag: tag)
            case .success:
                self.update(
                    offset: Self.counterMarkerOffset,
                    data: TumoCardNFCContract.counterMarker,
                    name: "Counter marker",
                    tag: tag
                ) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case let .failure(error): self.fail(error, tag: tag)
                    case .success:
                        self.counterDirty = true
                        self.verifyNotesIsolation(tag)
                    }
                }
            }
        }
    }

    func verifyNotesIsolation(_ tag: TumoCardNFCTagHandle) {
        select(TumoCardNFCContract.notesAID, name: "Notes", tag: tag) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error): self.fail(error, tag: tag)
            case .success:
                self.read(Self.notesLength, name: "Verify Notes isolated", tag: tag) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case let .failure(error): self.fail(error, tag: tag)
                    case let .success(data):
                        guard data == self.notesOriginal else {
                            self.fail(.stateMismatch("Notes isolation"), tag: tag)
                            return
                        }
                        self.update(
                            offset: Self.notesMarkerOffset,
                            data: TumoCardNFCContract.notesMarker,
                            name: "Notes marker",
                            tag: tag
                        ) { [weak self] result in
                            guard let self else { return }
                            switch result {
                            case let .failure(error): self.fail(error, tag: tag)
                            case .success:
                                self.notesDirty = true
                                self.verifyBothMarkers(tag)
                            }
                        }
                    }
                }
            }
        }
    }

    func verifyBothMarkers(_ tag: TumoCardNFCTagHandle) {
        read(Self.notesLength, name: "Verify Notes marker", tag: tag) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error): self.fail(error, tag: tag)
            case let .success(data):
                guard data.suffix(TumoCardNFCContract.notesMarker.count) == TumoCardNFCContract.notesMarker else {
                    self.fail(.stateMismatch("Notes marker"), tag: tag)
                    return
                }
                self.select(TumoCardNFCContract.counterAID, name: "Counter again", tag: tag) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case let .failure(error): self.fail(error, tag: tag)
                    case .success:
                        self.read(Self.counterLength, name: "Verify Counter marker", tag: tag) { [weak self] result in
                            guard let self else { return }
                            switch result {
                            case let .failure(error): self.fail(error, tag: tag)
                            case let .success(data):
                                guard data.suffix(TumoCardNFCContract.counterMarker.count) == TumoCardNFCContract.counterMarker else {
                                    self.fail(.stateMismatch("Counter marker"), tag: tag)
                                    return
                                }
                                self.restoreStates(tag) { [weak self] result in
                                    guard let self else { return }
                                    switch result {
                                    case let .failure(error): self.finishFailure(error, restoreFailed: true)
                                    case .success:
                                        self.append(self.usbHandoffDetected ? "USB handoff detected" : "USB handoff not staged")
                                        self.finish(
                                            .passed(usbHandoff: self.usbHandoffDetected),
                                            alert: "TumoCard NFC smoke passed."
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func select(
        _ aid: Data,
        name: String,
        tag: TumoCardNFCTagHandle,
        completion: @escaping (Result<Void, SmokeError>) -> Void
    ) {
        guard let command = TumoCardNFCContract.select(aid) else {
            completion(.failure(.invalidCommand))
            return
        }
        expect(command, status: 0x9000, tag: tag, step: "SELECT \(name)", completion: completion)
    }

    func read(
        _ length: Int,
        name: String,
        tag: TumoCardNFCTagHandle,
        completion: @escaping (Result<Data, SmokeError>) -> Void
    ) {
        guard let command = TumoCardNFCContract.read(length: length) else {
            completion(.failure(.invalidCommand))
            return
        }
        send(command, tag: tag, step: name) { result in
            switch result {
            case let .failure(error): completion(.failure(error))
            case let .success(response):
                guard response.status == 0x9000 else {
                    completion(.failure(.command(name, expected: 0x9000, actual: response.status)))
                    return
                }
                completion(.success(response.data))
            }
        }
    }

    func update(
        offset: Int,
        data: Data,
        name: String,
        tag: TumoCardNFCTagHandle,
        completion: @escaping (Result<Void, SmokeError>) -> Void
    ) {
        guard let command = TumoCardNFCContract.update(offset: offset, data: data) else {
            completion(.failure(.invalidCommand))
            return
        }
        expect(command, status: 0x9000, tag: tag, step: "UPDATE \(name)", completion: completion)
    }

    func expect(
        _ command: Data,
        status expectedStatus: UInt16,
        tag: TumoCardNFCTagHandle,
        step: String,
        completion: @escaping (Result<Void, SmokeError>) -> Void
    ) {
        send(command, tag: tag, step: step) { result in
            switch result {
            case let .failure(error): completion(.failure(error))
            case let .success(response):
                guard response.status == expectedStatus else {
                    completion(.failure(.command(step, expected: expectedStatus, actual: response.status)))
                    return
                }
                completion(.success(()))
            }
        }
    }

    func send(
        _ command: Data,
        tag: TumoCardNFCTagHandle,
        step: String,
        completion: @escaping (Result<Response, SmokeError>) -> Void
    ) {
        guard let apdu = NFCISO7816APDU(data: command) else {
            completion(.failure(.invalidCommand))
            return
        }
        state = .running(step)
        append(step)
        tag.tag.sendCommand(apdu: apdu) { data, sw1, sw2, error in
            if let error {
                completion(.failure(.transport(error.localizedDescription)))
                return
            }
            completion(.success(Response(
                data: data,
                status: TumoVMNFCContract.status(sw1: sw1, sw2: sw2)
            )))
        }
    }

    func restoreStates(
        _ tag: TumoCardNFCTagHandle,
        completion: @escaping (Result<Void, SmokeError>) -> Void
    ) {
        guard !restoring else { return }
        restoring = true
        restoreCounter(tag) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error):
                self.restoring = false
                completion(.failure(error))
            case .success:
                self.restoreNotes(tag) { result in
                    self.restoring = false
                    completion(result)
                }
            }
        }
    }

    func restoreCounter(
        _ tag: TumoCardNFCTagHandle,
        completion: @escaping (Result<Void, SmokeError>) -> Void
    ) {
        guard counterDirty else {
            completion(.success(()))
            return
        }
        restore(
            aid: TumoCardNFCContract.counterAID,
            name: "Counter",
            original: counterOriginal,
            tag: tag
        ) { [weak self] result in
            if case .success = result { self?.counterDirty = false }
            completion(result)
        }
    }

    func restoreNotes(
        _ tag: TumoCardNFCTagHandle,
        completion: @escaping (Result<Void, SmokeError>) -> Void
    ) {
        guard notesDirty else {
            completion(.success(()))
            return
        }
        restore(
            aid: TumoCardNFCContract.notesAID,
            name: "Notes",
            original: notesOriginal,
            tag: tag
        ) { [weak self] result in
            if case .success = result { self?.notesDirty = false }
            completion(result)
        }
    }

    func restore(
        aid: Data,
        name: String,
        original: Data,
        tag: TumoCardNFCTagHandle,
        completion: @escaping (Result<Void, SmokeError>) -> Void
    ) {
        select(aid, name: "\(name) restore", tag: tag) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error): completion(.failure(error))
            case .success:
                self.update(offset: 0, data: original, name: "\(name) restore", tag: tag) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case let .failure(error): completion(.failure(error))
                    case .success:
                        self.read(original.count, name: "Verify \(name) restore", tag: tag) { result in
                            switch result {
                            case let .failure(error): completion(.failure(error))
                            case let .success(data):
                                guard data == original else {
                                    completion(.failure(.stateMismatch("\(name) restore")))
                                    return
                                }
                                completion(.success(()))
                            }
                        }
                    }
                }
            }
        }
    }

    func fail(_ error: SmokeError, tag: TumoCardNFCTagHandle) {
        guard counterDirty || notesDirty else {
            finishFailure(error, restoreFailed: false)
            return
        }
        restoreStates(tag) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success: self.finishFailure(error, restoreFailed: false)
            case .failure: self.finishFailure(error, restoreFailed: true)
            }
        }
    }

    func finishFailure(_ error: SmokeError, restoreFailed: Bool) {
        let suffix = restoreFailed ? "; state restore failed" : ""
        finish(
            .failed((error.errorDescription ?? "TumoCard NFC smoke failed") + suffix),
            alert: restoreFailed ? "Smoke failed; check applet state." : "Smoke failed; state restored."
        )
    }
}

struct TumoCardNFCSmokeView: View {
    @StateObject private var controller = TumoCardNFCSmokeController()

    var body: some View {
        CardScroll {
            SectionCard(title: "TumoCard OS", systemImage: "rectangle.stack.badge.person.crop") {
                HStack {
                    StatusPill(text: controller.state.label, color: controller.state.color)
                    Spacer()
                    Text("AID 01 + 02")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Button {
                    controller.start()
                } label: {
                    Label("Run NFC Smoke", systemImage: "wave.3.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.readingAvailable || controller.state == .scanning)

                if case let .passed(usbHandoff) = controller.state {
                    Label(
                        usbHandoff ? "USB-to-NFC shared state confirmed" : "NFC routing passed; USB handoff was not staged",
                        systemImage: usbHandoff ? "checkmark.circle.fill" : "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(usbHandoff ? .green : .secondary)
                }
            }

            if !controller.steps.isEmpty {
                SectionCard(title: "Session", systemImage: "list.bullet.rectangle") {
                    ForEach(Array(controller.steps.enumerated()), id: \.offset) { _, step in
                        Text(step)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            if case let .failed(message) = controller.state {
                SectionCard(title: "Failure", systemImage: "exclamationmark.triangle") {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("TumoCard NFC")
        .navigationBarTitleDisplayMode(.inline)
    }
}
