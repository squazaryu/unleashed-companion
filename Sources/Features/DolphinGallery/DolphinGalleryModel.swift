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
        case notInstalled
        case installing
        case installed
        case failed(String)
    }

    private struct Preferences: Codable {
        var enabled: Bool
        var order: DolphinProfileOrder
        var timing: DolphinProfileTiming
        var durationSeconds: Int
        var activeCollectionID: UUID
        var collections: [DolphinCollection]
        var installedPackIDs: Set<String>?
    }

    static let allCollectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000132")!

    @Published var enabled: Bool { didSet { persist() } }
    @Published var order: DolphinProfileOrder { didSet { persist() } }
    @Published var timing: DolphinProfileTiming { didSet { persist() } }
    @Published var durationSeconds: Int { didSet { persist() } }
    @Published var activeCollectionID: UUID { didSet { persist() } }
    @Published private(set) var collections: [DolphinCollection] { didSet { persist() } }
    @Published private(set) var installedPackIDs: Set<String> { didSet { persist() } }
    @Published private(set) var packPhases: [String: PackPhase] = [:]
    @Published private(set) var phase: Phase = .idle

    private let service: DolphinProfileService
    private let packInstaller: DolphinPackInstaller
    private let defaults: UserDefaults
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
            enabled = saved.enabled
            order = saved.order
            timing = saved.timing
            durationSeconds = min(
                DolphinDesktopProfile.maximumDuration,
                max(DolphinDesktopProfile.minimumDuration, saved.durationSeconds)
            )
            activeCollectionID = saved.activeCollectionID
            collections = saved.collections
            installedPackIDs = saved.installedPackIDs ?? []
        } else {
            enabled = false
            order = .random
            timing = .original
            durationSeconds = 60
            activeCollectionID = Self.allCollectionID
            collections = []
            installedPackIDs = []
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
        DolphinCatalog.legacy + DolphinPackCatalog.installable
            .filter { installedPackIDs.contains($0.id) }
            .map(\.animation)
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

    func packPhase(_ descriptor: DolphinPackDescriptor) -> PackPhase {
        packPhases[descriptor.id] ?? (installedPackIDs.contains(descriptor.id) ? .installed : .unknown)
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

        let manifestIDs = await packInstaller.installedIDs()
        let catalogIDs = Set(DolphinPackCatalog.installable.map(\.id))
        installedPackIDs = manifestIDs.intersection(catalogIDs)
        for descriptor in DolphinPackCatalog.installable {
            packPhases[descriptor.id] = installedPackIDs.contains(descriptor.id)
                ? .installed
                : .notInstalled
        }
    }

    func install(_ descriptor: DolphinPackDescriptor) async {
        guard packPhase(descriptor) != .installing else { return }
        packPhases[descriptor.id] = .installing
        do {
            try await packInstaller.install(descriptor)
            installedPackIDs.insert(descriptor.id)
            packPhases[descriptor.id] = .installed
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
        do {
            let collection = activeCollection
            let availableIDs = Set(availableAnimations.map(\.id))
            let selectsAll = Set(collection.animationIDs) == availableIDs
            try await service.apply(DolphinDesktopProfile(
                enabled: enabled,
                collection: collection.name,
                order: order,
                timing: timing,
                durationSeconds: durationSeconds,
                animationIDs: selectsAll ? [] : collection.animationIDs,
                selection: selectsAll ? .all : .explicit
            ))
            phase = .applied
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func resetToOriginal() async {
        phase = .applying
        do {
            try await service.apply(DolphinDesktopProfile(
                enabled: false,
                collection: "All animations",
                order: .random,
                timing: .original,
                durationSeconds: 60,
                animationIDs: []
            ))
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
            installedPackIDs: installedPackIDs
        )
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: preferencesKey)
        }
    }
}
