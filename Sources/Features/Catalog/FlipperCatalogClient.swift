import Foundation
import SwiftUI

// MARK: - Models
//
// Mirrors the JSON returned by https://catalog.flipperzero.one/api/v0/0 — the same
// public REST API the official Flipper mobile apps and Flipper Lab use to browse and
// install community apps. Undocumented but stable; verified against live responses.

struct CatalogSDK: Decodable, Equatable {
    let target: String
    let api: String
}

struct CatalogBuild: Decodable, Equatable {
    let id: String
    let sdk: CatalogSDK
    let fapHash: String

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case sdk
        case fapHash = "fap_hash"
    }
}

struct CatalogSourceLink: Decodable, Equatable {
    let uri: String
}

struct CatalogLinks: Decodable, Equatable {
    let sourceCode: CatalogSourceLink?

    enum CodingKeys: String, CodingKey {
        case sourceCode = "source_code"
    }
}

/// The "version" nested inside an application. The list/search/featured endpoints
/// return a slimmer shape (no description/changelog/links); the single-application
/// detail endpoint fills those in. Modeled as one optional-heavy struct rather than
/// two near-duplicates.
struct CatalogVersion: Decodable, Equatable {
    let id: String
    let name: String
    let version: String
    let shortDescription: String
    let description: String?
    let changelog: String?
    let currentBuild: CatalogBuild?
    let iconURI: String
    let screenshots: [String]
    let links: CatalogLinks?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case name, version
        case shortDescription = "short_description"
        case description, changelog
        case currentBuild = "current_build"
        case iconURI = "icon_uri"
        case screenshots, links
    }
}

struct CatalogApplication: Identifiable, Decodable, Equatable {
    let id: String
    let categoryID: String
    let alias: String
    let author: String
    let downloads: Int
    let currentVersion: CatalogVersion

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case categoryID = "category_id"
        case alias, author, downloads
        case currentVersion = "current_version"
    }
}

struct CatalogCategory: Identifiable, Decodable, Equatable {
    let id: String
    let name: String
    let color: String
    let iconURI: String?
    let applications: Int

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case name, color
        case iconURI = "icon_uri"
        case applications
    }

    var tint: Color { Color(hex: color) }
}

extension Color {
    /// Parses a bare 6-digit hex string (no `#`), as returned by the catalog's
    /// category `color` field.
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Client

/// Talks to the public Flipper Application Catalog API — browsing, search, and
/// downloading .fap builds. This is a third-party (non-Flipper-device) HTTP API;
/// installing a downloaded build onto the connected Flipper is a separate step via
/// `FlipperStorage`.
final class FlipperCatalogClient {
    static let shared = FlipperCatalogClient()

    enum CatalogError: LocalizedError {
        case badResponse(Int)
        case noBuildAvailable

        var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "Catalog request failed (HTTP \(code))."
            case .noBuildAvailable: return "This app doesn't have a published build yet."
            }
        }
    }

    private let base = URL(string: "https://catalog.flipperzero.one/api/v0/0")!
    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session
        self.decoder = JSONDecoder()
    }

    func categories() async throws -> [CatalogCategory] {
        try await get([CatalogCategory].self, path: "category")
    }

    func featured() async throws -> [CatalogApplication] {
        try await get([CatalogApplication].self, path: "application/featured")
    }

    enum SortField: String {
        case updatedAt = "updated_at"
        case name = "name"
    }

    /// `query` must be at least 2 characters (API requirement) — pass nil/empty to browse unfiltered.
    func applications(query: String? = nil, categoryID: String? = nil,
                       sortBy: SortField = .updatedAt, ascending: Bool = false,
                       limit: Int = 60, offset: Int = 0) async throws -> [CatalogApplication] {
        var items: [URLQueryItem] = [
            .init(name: "limit", value: String(limit)),
            .init(name: "offset", value: String(offset)),
            .init(name: "sort_by", value: sortBy.rawValue),
            .init(name: "sort_order", value: ascending ? "1" : "-1"),
        ]
        if let query, query.trimmingCharacters(in: .whitespaces).count >= 2 {
            items.append(.init(name: "query", value: query))
        }
        if let categoryID { items.append(.init(name: "category_id", value: categoryID)) }
        return try await get([CatalogApplication].self, path: "application", query: items)
    }

    func detail(id: String) async throws -> CatalogApplication {
        try await get(CatalogApplication.self, path: "application/\(id)")
    }

    /// Path to a build's `.fap` asset. The `version/` segment needs the VERSION's
    /// `_id` (`CatalogVersion.id`), NOT the build document's `_id` — passing the
    /// build id here 404s for every app in the catalog (verified against the live
    /// API: build-id → 404, version-id → 200 with a matching `fap_hash`).
    static func buildAssetPath(versionID: String, build: CatalogBuild) -> String {
        "application/version/\(versionID)/build/\(build.sdk.target)/\(build.sdk.api)"
    }

    /// Downloads the raw `.fap` bytes for an app's current build. Uses the build's
    /// own `sdk.target`/`sdk.api` (the exact pair it was compiled for) rather than
    /// the connected device's — callers should warn if the device target differs.
    func downloadBuild(versionID: String, _ build: CatalogBuild) async throws -> Data {
        let url = base.appendingPathComponent(Self.buildAssetPath(versionID: versionID, build: build))
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CatalogError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }

    private func get<T: Decodable>(_ type: T.Type, path: String, query: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        let (data, response) = try await session.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CatalogError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try decoder.decode(T.self, from: data)
    }
}
