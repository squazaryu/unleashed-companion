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

    private struct Preferences: Codable {
        var enabled: Bool
        var order: DolphinProfileOrder
        var timing: DolphinProfileTiming
        var durationSeconds: Int
        var activeCollectionID: UUID
        var collections: [DolphinCollection]
    }

    static let allCollectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000132")!

    @Published var enabled: Bool { didSet { persist() } }
    @Published var order: DolphinProfileOrder { didSet { persist() } }
    @Published var timing: DolphinProfileTiming { didSet { persist() } }
    @Published var durationSeconds: Int { didSet { persist() } }
    @Published var activeCollectionID: UUID { didSet { persist() } }
    @Published private(set) var collections: [DolphinCollection] { didSet { persist() } }
    @Published private(set) var phase: Phase = .idle

    private let service: DolphinProfileService
    private let defaults: UserDefaults
    private let preferencesKey = "dolphinGallery.preferences.v1"
    private var suppressPersistence = false

    init(
        service: DolphinProfileService = DolphinProfileService(),
        defaults: UserDefaults = .standard
    ) {
        self.service = service
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
        } else {
            enabled = false
            order = .random
            timing = .original
            durationSeconds = 60
            activeCollectionID = Self.allCollectionID
            collections = []
        }

        if collection(id: activeCollectionID) == nil {
            activeCollectionID = Self.allCollectionID
        }
    }

    var allCollection: DolphinCollection {
        DolphinCollection(
            id: Self.allCollectionID,
            name: "All animations",
            animationIDs: DolphinCatalog.animations.map(\.id)
        )
    }

    var availableCollections: [DolphinCollection] {
        [allCollection] + collections
    }

    var activeCollection: DolphinCollection {
        collection(id: activeCollectionID) ?? allCollection
    }

    var canApply: Bool {
        !activeCollection.animationIDs.isEmpty &&
            (DolphinDesktopProfile.minimumDuration...DolphinDesktopProfile.maximumDuration)
                .contains(durationSeconds)
    }

    var isBusy: Bool {
        phase == .loading || phase == .applying
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

    func apply() async {
        guard canApply else {
            phase = .failed(DolphinProfileError.emptyCollection.localizedDescription)
            return
        }

        phase = .applying
        do {
            let collection = activeCollection
            try await service.apply(DolphinDesktopProfile(
                enabled: enabled,
                collection: collection.name,
                order: order,
                timing: timing,
                durationSeconds: durationSeconds,
                animationIDs: collection.animationIDs
            ))
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

        if profile.animationIDs == allCollection.animationIDs {
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
            collections: collections
        )
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: preferencesKey)
        }
    }
}
