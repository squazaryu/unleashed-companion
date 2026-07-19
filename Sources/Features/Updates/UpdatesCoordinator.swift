import Combine
import Foundation

/// App-owned update state. Downloads and installs may outlive the screen that started
/// them, so their ownership cannot be tied to a SwiftUI `.task` modifier.
@MainActor
final class UpdatesCoordinator: ObservableObject {
    let plugins = PluginUpdater()
    let packages = TumoflipUpdater()
    let firmware = FirmwareLibrary()

    private var pluginLoadTask: Task<Void, Never>?
    private var packageLoadTask: Task<Void, Never>?
    private var revalidationTask: Task<Void, Never>?
    private var observations = Set<AnyCancellable>()

    init() {
        Publishers.Merge3(
            plugins.objectWillChange,
            packages.objectWillChange,
            firmware.objectWillChange
        )
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observations)
    }

    func loadIfNeeded(recoverPackages: Bool) {
        firmware.loadIfNeeded()
        if pluginLoadTask == nil, plugins.shouldLoadCatalog {
            pluginLoadTask = Task { [weak self] in
                guard let self else { return }
                await self.plugins.check()
                self.pluginLoadTask = nil
            }
        }

        if packageLoadTask == nil, packages.shouldLoadManifest {
            packageLoadTask = Task { [weak self] in
                guard let self else { return }
                await self.packages.reload(recover: recoverPackages)
                self.packageLoadTask = nil
            }
        }
    }

    /// BLE state can flap through connected/disconnected while a transfer is active.
    /// Coalesce those events and only refresh compatibility after the link settles at ready.
    func revalidateAfterReady(_ state: FlipperConnectionState) {
        guard state == .ready else { return }
        revalidationTask?.cancel()
        revalidationTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await self.plugins.validateCompatibility()
            await self.packages.validateCompatibility()
            self.revalidationTask = nil
        }
    }
}

enum UpdateTaskCancellation {
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }
}
