import Combine
import Foundation

protocol TumoSpectrumStorageReading {
    func list(_ path: String) async throws -> [FlipperFile]
    func read(_ path: String) async throws -> Data
}

extension FlipperStorage: TumoSpectrumStorageReading {}

@MainActor
final class TumoSpectrumViewModel: ObservableObject {
    @Published private(set) var document: TumoSpectrumDocument?
    @Published private(set) var reportFileName: String?
    @Published private(set) var reportFiles: [FlipperFile] = []
    @Published private(set) var isLoading = false
    @Published private(set) var status = "Waiting for a TumoSpectrum report."
    @Published private(set) var errorMessage: String?

    private let storage: any TumoSpectrumStorageReading
    private let ble: FlipperBLE
    private var bridgeSubscription: AnyCancellable?
    private var connectionSubscription: AnyCancellable?
    private var loadTask: Task<Void, Never>?

    var report: TumoSpectrumReport? {
        guard case .capture(let report) = document else { return nil }
        return report
    }

    var captureSet: TumoSpectrumCaptureSetReport? {
        guard case .captureSet(let captureSet) = document else { return nil }
        return captureSet
    }

    init(storage: any TumoSpectrumStorageReading = FlipperStorage(), ble: FlipperBLE = .shared) {
        self.storage = storage
        self.ble = ble
    }

    func start() {
        guard bridgeSubscription == nil else { return }
        bridgeSubscription = ble.appBridgeIn
            .receive(on: DispatchQueue.main)
            .filter(TumoSpectrumAnnouncement.accepts)
            .sink { [weak self] frame in
                guard let self else { return }
                do {
                    let announcement = try TumoSpectrumAnnouncement.parse(frame.payload)
                    self.open(fileName: announcement.fileName)
                } catch {
                    self.errorMessage = error.localizedDescription
                    self.status = "Report announcement rejected."
                }
            }
        connectionSubscription = ble.$state
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                if state == .ready {
                    self.refresh()
                } else if self.document == nil {
                    self.errorMessage = nil
                    self.status = "Connect Flipper to load saved reports."
                }
            }
    }

    func stop() {
        bridgeSubscription?.cancel()
        bridgeSubscription = nil
        connectionSubscription?.cancel()
        connectionSubscription = nil
        loadTask?.cancel()
        loadTask = nil
    }

    func refresh() {
        guard ble.state == .ready else {
            errorMessage = nil
            status = "Connect Flipper to load saved reports."
            return
        }
        runLoad { [storage] in
            let files = try await storage.list(TumoSpectrumAnnouncement.reportDirectory)
                .filter { !$0.isDirectory && TumoSpectrumAnnouncement.isSafeReportFileName($0.name) }
                .sorted {
                    TumoSpectrumAnnouncement.sortStamp($0.name) >
                        TumoSpectrumAnnouncement.sortStamp($1.name)
                }
            guard let latest = files.first else {
                return (files, nil, nil)
            }
            let data = try await storage.read(latest.path)
            return (files, latest.name, try TumoSpectrumDocument.decodeValidated(data))
        }
    }

    func open(fileName: String) {
        guard TumoSpectrumAnnouncement.isSafeReportFileName(fileName) else {
            errorMessage = TumoSpectrumReportError.malformedAnnouncement.localizedDescription
            return
        }
        runLoad { [storage] in
            let path = "\(TumoSpectrumAnnouncement.reportDirectory)/\(fileName)"
            let data = try await storage.read(path)
            return ([], fileName, try TumoSpectrumDocument.decodeValidated(data))
        }
    }

    private func runLoad(
        _ operation: @escaping () async throws -> ([FlipperFile], String?, TumoSpectrumDocument?)
    ) {
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        status = "Loading report…"
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (files, fileName, document) = try await operation()
                try Task.checkCancellation()
                if !files.isEmpty || document == nil { self.reportFiles = Array(files.prefix(12)) }
                if let document {
                    self.document = document
                    self.reportFileName = fileName
                    self.status = "Report loaded from Flipper."
                } else {
                    self.document = nil
                    self.reportFileName = nil
                    self.status = "No saved TumoSpectrum reports found."
                }
            } catch is CancellationError {
                return
            } catch {
                self.errorMessage = error.localizedDescription
                self.status = "Could not load the report."
            }
            self.isLoading = false
        }
    }
}
