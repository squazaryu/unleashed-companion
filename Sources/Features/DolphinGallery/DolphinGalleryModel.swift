import Foundation

@MainActor
final class DolphinGalleryModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case applying
        case applied
        case failed(String)
    }

    enum PackPhase: Equatable {
        case unknown
        case checking
        case notDownloaded
        case downloading
        case downloaded
        case failed(String)
    }

    private struct Preferences: Codable {
        var enabled: Bool
        var order: DolphinProfileOrder
        var timing: DolphinProfileTiming
        var durationSeconds: Int
        var activeCollectionID: UUID
        var collections: [DolphinCollection]
        // Kept under the original key so 1.6.28 preferences migrate without data loss.
        var installedPackIDs: Set<String>?
    }

    static let allCollectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000132")!

    @Published var enabled: Bool { didSet { persist() } }
    @Published var order: DolphinProfileOrder { didSet { persist() } }
    @Published var timing: DolphinProfileTiming { didSet { persist() } }
    @Published var durationSeconds: Int { didSet { persist() } }
    @Published var activeCollectionID: UUID { didSet { persist() } }
    @Published private(set) var collections: [DolphinCollection] { didSet { persist() } }
    @Published private(set) var cachedPackIDs: Set<String> { didSet { persist() } }
    @Published private(set) var packPhases: [String: PackPhase] = [:]
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transferProgress: DolphinPackSyncProgress?
    private(set) var hasLocalPreferences: Bool

    private let service: DolphinProfileService
    private let packInstaller: DolphinPackInstaller
    private let defaults: UserDefaults
    private let transferReporter = TransferActivityReporter(channel: .ble)
    private let preferencesKey = "dolphinGallery.preferences.v1"
    private var suppressPersistence = false

    init(
        service: DolphinProfileService = DolphinProfileService(),
        packInstaller: DolphinPackInstaller = DolphinPackInstaller(),
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.packInstaller = packInstaller
        self.defaults = defaults

        if let data = defaults.data(forKey: preferencesKey),
           let saved = try? JSONDecoder().decode(Preferences.self, from: data) {
            hasLocalPreferences = true
            enabled = saved.enabled
            order = saved.order
            timing = saved.timing
            durationSeconds = min(
                DolphinDesktopProfile.maximumDuration,
                max(DolphinDesktopProfile.minimumDuration, saved.durationSeconds)
            )
            activeCollectionID = saved.activeCollectionID
            collections = saved.collections
            cachedPackIDs = saved.installedPackIDs ?? []
        } else {
            hasLocalPreferences = false
            enabled = false
            order = .random
            timing = .original
            durationSeconds = 60
            activeCollectionID = Self.allCollectionID
            collections = []
            cachedPackIDs = []
        }

        if collection(id: activeCollectionID) == nil {
            activeCollectionID = Self.allCollectionID
        }
    }

    var allCollection: DolphinCollection {
        DolphinCollection(
            id: Self.allCollectionID,
            name: "All animations",
            animationIDs: availableAnimations.map(\.id)
        )
    }

    var availableAnimations: [DolphinAnimation] {
        DolphinCatalog.legacy + DolphinPackCatalog.installable.map(\.animation)
    }

    var availableCollections: [DolphinCollection] {
        [allCollection] + collections
    }

    var activeCollection: DolphinCollection {
        let selected = collection(id: activeCollectionID) ?? allCollection
        let availableIDs = Set(availableAnimations.map(\.id))
        return DolphinCollection(
            id: selected.id,
            name: selected.name,
            animationIDs: selected.animationIDs.filter(availableIDs.contains)
        )
    }

    var canApply: Bool {
        !activeCollection.animationIDs.isEmpty &&
            (DolphinDesktopProfile.minimumDuration...DolphinDesktopProfile.maximumDuration)
                .contains(durationSeconds)
    }

    var isBusy: Bool {
        phase == .loading || phase == .applying
    }

    var shouldLoadInitialProfileFromDevice: Bool {
        !hasLocalPreferences
    }

    func packPhase(_ descriptor: DolphinPackDescriptor) -> PackPhase {
        packPhases[descriptor.id] ?? (cachedPackIDs.contains(descriptor.id) ? .downloaded : .unknown)
    }

    func animations(for source: DolphinLibrarySource) -> [DolphinAnimation] {
        availableAnimations.filter { $0.source == source }
    }

    func selectCollection(_ id: UUID) {
        guard collection(id: id) != nil else { return }
        activeCollectionID = id
    }

    func upsert(_ collection: DolphinCollection) {
        guard collection.id != Self.allCollectionID else { return }
        if let index = collections.firstIndex(where: { $0.id == collection.id }) {
            collections[index] = collection
        } else {
            collections.append(collection)
        }
        collections.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        activeCollectionID = collection.id
    }

    func deleteCollection(_ id: UUID) {
        guard id != Self.allCollectionID else { return }
        collections.removeAll { $0.id == id }
        if activeCollectionID == id {
            activeCollectionID = Self.allCollectionID
        }
    }

    func loadFromDevice() async {
        phase = .loading
        do {
            guard let profile = try await service.load() else {
                phase = .idle
                return
            }
            importProfile(profile)
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func refreshPackStates() async {
        for descriptor in DolphinPackCatalog.installable {
            packPhases[descriptor.id] = .checking
        }

        cachedPackIDs = await packInstaller.cachedIDs(in: DolphinPackCatalog.installable)
        for descriptor in DolphinPackCatalog.installable {
            packPhases[descriptor.id] = cachedPackIDs.contains(descriptor.id)
                ? .downloaded
                : .notDownloaded
        }
    }

    func download(_ descriptor: DolphinPackDescriptor) async {
        guard packPhase(descriptor) != .downloading else { return }
        packPhases[descriptor.id] = .downloading
        do {
            try await packInstaller.cache(descriptor)
            cachedPackIDs.insert(descriptor.id)
            packPhases[descriptor.id] = .downloaded
        } catch {
            packPhases[descriptor.id] = .failed(error.localizedDescription)
        }
    }

    func apply() async {
        guard canApply else {
            phase = .failed(DolphinProfileError.emptyCollection.localizedDescription)
            return
        }

        phase = .applying
        transferProgress = nil
        var reportingToFlipper = false
        defer {
            transferProgress = nil
            if reportingToFlipper {
                transferReporter.end()
            }
        }
        do {
            let collection = activeCollection
            let selectedIDs = Set(collection.animationIDs)
            let selectedPacks = DolphinPackCatalog.installable.filter { selectedIDs.contains($0.id) }
            if enabled {
                _ = await transferReporter.prepare()
                transferReporter.begin("dolphin collection")
                reportingToFlipper = true
                try await packInstaller.synchronize(selectedPacks) { [weak self] update in
                    await self?.setTransferProgress(update)
                }
                cachedPackIDs.formUnion(selectedPacks.map(\.id))
                for descriptor in selectedPacks {
                    packPhases[descriptor.id] = .downloaded
                }
            }
            transferProgress = DolphinPackSyncProgress(
                stage: .profile,
                completed: 0,
                total: 1,
                item: collection.name
            )
            try await service.apply(DolphinDesktopProfile(
                enabled: enabled,
                collection: collection.name,
                order: order,
                timing: timing,
                durationSeconds: durationSeconds,
                animationIDs: collection.animationIDs,
                selection: .explicit
            ))
            transferProgress = DolphinPackSyncProgress(
                stage: .profile,
                completed: 1,
                total: 1,
                item: nil
            )
            phase = .applied
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func resetToOriginal() async {
        phase = .applying
        transferProgress = nil
        _ = await transferReporter.prepare()
        transferReporter.begin("dolphin reset")
        defer {
            transferProgress = nil
            transferReporter.end()
        }
        do {
            try await packInstaller.resetToOriginal { [weak self] update in
                await self?.setTransferProgress(update)
            }
            transferProgress = DolphinPackSyncProgress(
                stage: .profile,
                completed: 0,
                total: 1,
                item: "Original settings"
            )
            try await service.resetToOriginal()
            transferProgress = DolphinPackSyncProgress(
                stage: .profile,
                completed: 1,
                total: 1,
                item: nil
            )
            suppressPersistence = true
            enabled = false
            order = .random
            timing = .original
            durationSeconds = 60
            activeCollectionID = Self.allCollectionID
            suppressPersistence = false
            persist()
            phase = .applied
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func collection(id: UUID) -> DolphinCollection? {
        if id == Self.allCollectionID { return allCollection }
        return collections.first { $0.id == id }
    }

    private func setTransferProgress(_ progress: DolphinPackSyncProgress) {
        transferProgress = progress
        transferReporter.progress(progress.item ?? transferLabel(for: progress.stage), force: progress.completed == 0)
    }

    private func transferLabel(for stage: DolphinPackSyncStage) -> String {
        switch stage {
        case .caching: return "preparing wallpapers"
        case .uploading: return "uploading wallpapers"
        case .removing: return "removing wallpapers"
        case .profile: return "applying wallpaper profile"
        }
    }

    private func importProfile(_ profile: DolphinDesktopProfile) {
        suppressPersistence = true
        enabled = profile.enabled
        order = profile.order
        timing = profile.timing
        durationSeconds = profile.durationSeconds

        if profile.selection == .all || profile.animationIDs == allCollection.animationIDs {
            activeCollectionID = Self.allCollectionID
        } else if let existing = collections.first(where: {
            $0.name == profile.collection && $0.animationIDs == profile.animationIDs
        }) {
            activeCollectionID = existing.id
        } else {
            let imported = DolphinCollection(
                id: UUID(),
                name: profile.collection.isEmpty ? "Imported" : profile.collection,
                animationIDs: profile.animationIDs
            )
            collections.append(imported)
            activeCollectionID = imported.id
        }
        suppressPersistence = false
        persist()
    }

    private func persist() {
        guard !suppressPersistence else { return }
        let preferences = Preferences(
            enabled: enabled,
            order: order,
            timing: timing,
            durationSeconds: durationSeconds,
            activeCollectionID: activeCollectionID,
            collections: collections,
            installedPackIDs: cachedPackIDs
        )
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: preferencesKey)
            hasLocalPreferences = true
        }
    }
}
