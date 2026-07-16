@preconcurrency import CoreNFC
import SwiftUI

private final class TumoVMNFCTagHandle: @unchecked Sendable {
    let tag: NFCISO7816Tag

    init(_ tag: NFCISO7816Tag) {
        self.tag = tag
    }
}

final class TumoVMNFCSmokeController: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case scanning
        case running(String)
        case passed(original: String)
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

    private var session: NFCTagReaderSession?
    private var original = Data()
    private var restoreAttempted = false

    var readingAvailable: Bool { NFCTagReaderSession.readingAvailable }

    func start() {
        guard readingAvailable else {
            state = .failed("NFC tag reading is unavailable")
            return
        }
        guard session == nil else { return }

        steps = []
        original = Data()
        restoreAttempted = false
        state = .scanning

        guard let session = NFCTagReaderSession(
            pollingOption: [.iso14443],
            delegate: self,
            queue: .main
        ) else {
            state = .failed("Could not create an NFC reader session")
            return
        }
        session.alertMessage = "Hold iPhone near the Flipper running TumoVM PoC."
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

extension TumoVMNFCSmokeController: NFCTagReaderSessionDelegate {
    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(
        _ session: NFCTagReaderSession,
        didInvalidateWithError error: Error
    ) {
        self.session = nil
        let nfcError = error as? NFCReaderError
        guard nfcError?.code != .readerSessionInvalidationErrorUserCanceled else { return }
        if case .passed = self.state { return }
        self.state = .failed(error.localizedDescription)
    }

    func tagReaderSession(
        _ session: NFCTagReaderSession,
        didDetect tags: [NFCTag]
    ) {
        guard tags.count == 1, case let .iso7816(tag) = tags[0] else {
            session.alertMessage = tags.count > 1 ? "Present only one NFC target." :
                                                    "TumoVM did not appear as ISO 7816."
            session.restartPolling()
            return
        }
        let tagHandle = TumoVMNFCTagHandle(tag)

        session.connect(to: tags[0]) { [weak self] error in
            guard let self else { return }
            if let error {
                self.finish(.failed(error.localizedDescription), alert: "Connection failed.")
                return
            }
            self.state = .running("SELECT")
            self.append("ISO 7816 connected")
            self.send(TumoVMNFCContract.select, to: tagHandle, step: "SELECT") { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error): self.fail(error, tag: tagHandle)
                case .success:
                    self.send(TumoVMNFCContract.read, to: tagHandle, step: "READ original") { [weak self] result in
                        guard let self else { return }
                        switch result {
                        case .failure(let error): self.fail(error, tag: tagHandle)
                        case .success(let data):
                            guard data.count == TumoVMNFCContract.marker.count else {
                                self.fail(.unexpectedLength(data.count), tag: tagHandle)
                                return
                            }
                            self.original = data
                            guard let update = TumoVMNFCContract.update(TumoVMNFCContract.marker) else {
                                self.fail(.invalidCommand, tag: tagHandle)
                                return
                            }
                            self.send(update, to: tagHandle, step: "UPDATE marker") { [weak self] result in
                                guard let self else { return }
                                switch result {
                                case .failure(let error): self.fail(error, tag: tagHandle)
                                case .success:
                                    self.send(TumoVMNFCContract.read, to: tagHandle, step: "VERIFY marker") { [weak self] result in
                                        guard let self else { return }
                                        switch result {
                                        case .failure(let error): self.fail(error, tag: tagHandle)
                                        case .success(let data):
                                            guard data == TumoVMNFCContract.marker else {
                                                self.restore(tagHandle) {
                                                    self.fail(.stateMismatch, tag: tagHandle, restored: true)
                                                }
                                                return
                                            }
                                            self.restore(tagHandle) { [weak self] in
                                                self?.verifyRestore(tagHandle)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private extension TumoVMNFCSmokeController {
    enum SmokeError: LocalizedError {
        case command(String, UInt16)
        case transport(String)
        case unexpectedLength(Int)
        case stateMismatch
        case invalidCommand

        var errorDescription: String? {
            switch self {
            case let .command(step, status): return "\(step) returned SW=\(String(format: "%04X", status))"
            case let .transport(message): return message
            case let .unexpectedLength(length): return "Expected four bytes, received \(length)"
            case .stateMismatch: return "State verification failed"
            case .invalidCommand: return "Could not build UPDATE command"
            }
        }
    }

    func send(
        _ command: Data,
        to tag: TumoVMNFCTagHandle,
        step: String,
        completion: @escaping (Result<Data, SmokeError>) -> Void
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
            let status = TumoVMNFCContract.status(sw1: sw1, sw2: sw2)
            guard status == 0x9000 else {
                completion(.failure(.command(step, status)))
                return
            }
            completion(.success(data))
        }
    }

    func restore(_ tag: TumoVMNFCTagHandle, completion: @escaping () -> Void) {
        restoreAttempted = true
        guard let update = TumoVMNFCContract.update(original) else {
            fail(.invalidCommand, tag: tag, restored: true)
            return
        }
        send(update, to: tag, step: "RESTORE original") { [weak self] result in
            guard let self else { return }
            if case let .failure(error) = result {
                self.fail(error, tag: tag, restored: true)
                return
            }
            completion()
        }
    }

    func verifyRestore(_ tag: TumoVMNFCTagHandle) {
        send(TumoVMNFCContract.read, to: tag, step: "VERIFY restore") { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): self.fail(error, tag: tag, restored: true)
            case .success(let data):
                guard data == self.original else {
                    self.fail(.stateMismatch, tag: tag, restored: true)
                    return
                }
                let hex = TumoVMNFCContract.hex(data)
                self.append("Original: \(hex)")
                self.finish(.passed(original: hex), alert: "TumoVM NFC smoke passed.")
            }
        }
    }

    func fail(_ error: SmokeError, tag: TumoVMNFCTagHandle, restored: Bool = false) {
        if !restored, restoreAttempted == false, !original.isEmpty {
            restore(tag) { [weak self] in
                self?.finish(.failed(error.localizedDescription), alert: "Smoke failed; state restored.")
            }
            return
        }
        finish(.failed(error.localizedDescription), alert: "TumoVM NFC smoke failed.")
    }
}

struct TumoVMNFCSmokeView: View {
    @StateObject private var controller = TumoVMNFCSmokeController()

    var body: some View {
        CardScroll {
            SectionCard(title: "TumoVM", systemImage: "wave.3.right.circle") {
                HStack {
                    StatusPill(text: controller.state.label, color: controller.state.color)
                    Spacer()
                    Text("F0 54 56 4D 01")
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
        .navigationTitle("TumoVM NFC")
        .navigationBarTitleDisplayMode(.inline)
    }
}
