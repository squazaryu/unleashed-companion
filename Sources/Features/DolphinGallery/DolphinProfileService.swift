import Foundation

protocol DolphinProfileFileStore {
    func read(_ path: String) async throws -> Data
    func write(_ path: String, data: Data) async throws
    func makeDirectory(_ path: String) async throws
    func delete(_ path: String) async throws
    func move(_ from: String, to newPath: String) async throws
    func exists(_ path: String) async -> Bool
}

extension FlipperStorage: DolphinProfileFileStore {}

struct DolphinProfileService {
    static let directory = "/ext/apps_data/tumoflip_customization"
    static let profilePath = "\(directory)/desktop_profile.txt"
    static let temporaryPath = "\(directory)/desktop_profile.txt.tmp"
    static let reloadPath = "\(directory)/reload.flag"

    let storage: any DolphinProfileFileStore

    init(storage: any DolphinProfileFileStore = FlipperStorage()) {
        self.storage = storage
    }

    func load() async throws -> DolphinDesktopProfile? {
        guard await storage.exists(Self.profilePath) else { return nil }
        let data = try await storage.read(Self.profilePath)
        return try DolphinDesktopProfile.decode(data)
    }

    func apply(_ profile: DolphinDesktopProfile) async throws {
        let data = try profile.encoded()
        try await storage.makeDirectory(Self.directory)

        if await storage.exists(Self.temporaryPath) {
            try await storage.delete(Self.temporaryPath)
        }

        do {
            try await storage.write(Self.temporaryPath, data: data)
            guard try await storage.read(Self.temporaryPath) == data else {
                throw DolphinProfileError.stagedProfileMismatch
            }
            if await storage.exists(Self.profilePath) {
                try await storage.delete(Self.profilePath)
            }
            try await storage.move(Self.temporaryPath, to: Self.profilePath)
            try await storage.write(Self.reloadPath, data: Data("reload\n".utf8))
        } catch {
            if await storage.exists(Self.temporaryPath) {
                try? await storage.delete(Self.temporaryPath)
            }
            throw error
        }
    }

    func resetToOriginal() async throws {
        try await storage.makeDirectory(Self.directory)
        if await storage.exists(Self.temporaryPath) {
            try await storage.delete(Self.temporaryPath)
        }
        if await storage.exists(Self.profilePath) {
            try await storage.delete(Self.profilePath)
        }
        try await storage.write(Self.reloadPath, data: Data("reload\n".utf8))
    }
}
