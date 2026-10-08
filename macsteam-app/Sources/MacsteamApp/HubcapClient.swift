import Foundation

struct HubcapGame: Codable, Identifiable, Sendable {
    let id: String
    let name: String

    var appID: Int? { Int(id) }
}

struct HubcapLibraryPage: Sendable {
    let totalCount: Int
    let games: [HubcapGame]
}

enum HubcapClientError: LocalizedError {
    case invalidAPIKey
    case invalidSearch
    case unauthorized
    case rateLimited
    case unavailable
    case http(Int)
    case invalidResponse(endpoint: String, preview: String)
    case invalidLuaResponse(appID: Int, preview: String)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "Enter a valid Hubcap API key."
        case .invalidSearch:
            return "Enter at least 3 characters to search Hubcap."
        case .unauthorized:
            return "The Hubcap API key is invalid, expired, or unauthorized."
        case .rateLimited:
            return "Hubcap's daily API limit for this key has been reached."
        case .unavailable:
            return "Hubcap doesn't have a Lua manifest for this game."
        case .http(let status):
            return "Hubcap returned HTTP \(status)."
        case .invalidResponse(let endpoint, let preview):
            return "Hubcap returned an unexpected response from \(endpoint): \(preview)"
        case .invalidLuaResponse(let appID, let preview):
            return "Hubcap returned invalid Lua for App \(appID). Response starts with: \(preview)"
        }
    }
}

private struct HubcapLibraryResponse: Decodable {
    let status: String
    let totalCount: Int
    let limit: Int
    let offset: Int
    let search: String?
    let sortBy: String?
    let games: [HubcapGame]

    enum CodingKeys: String, CodingKey {
        case status
        case totalCount = "total_count"
        case limit
        case offset
        case search
        case sortBy = "sort_by"
        case games
    }
}

extension HubcapGame {
    enum CodingKeys: String, CodingKey {
        case id = "game_id"
        case name = "game_name"
    }
}

final class HubcapClient: @unchecked Sendable {
    static let apiKeysURL = URL(string: "https://hubcapmanifest.com/api-keys/")!

    private let session: URLSession
    private let baseURL = URL(string: "https://hubcapmanifest.com")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func allGames(apiKey: String) async throws -> [HubcapGame] {
        var offset = 0
        var all: [HubcapGame] = []

        while true {
            let page = try await libraryPage(
                apiKey: apiKey,
                limit: 1000,
                offset: offset
            )
            all.append(contentsOf: page.games)

            if page.games.isEmpty || all.count >= page.totalCount {
                break
            }

            let nextOffset = offset + page.games.count
            guard nextOffset > offset else {
                throw HubcapClientError.invalidResponse(
                    endpoint: "/api/v1/library",
                    preview: "pagination did not advance"
                )
            }
            offset = nextOffset
        }

        return all
    }

    func libraryPage(apiKey: String, limit: Int = 1000, offset: Int = 0) async throws -> HubcapLibraryPage {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/v1/library"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 1000))),
            URLQueryItem(name: "offset", value: String(max(offset, 0))),
            URLQueryItem(name: "sort_by", value: "name"),
        ]

        let request = try makeRequest(
            url: components.url!,
            apiKey: apiKey,
            accept: "application/json"
        )
        let (data, response) = try await session.data(for: request)
        try validate(response)

        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes.removeFirst(3)
        }

        do {
            let payload = try JSONDecoder().decode(HubcapLibraryResponse.self, from: bytes)
            guard payload.status == "success" else {
                throw HubcapClientError.invalidResponse(
                    endpoint: "/api/v1/library",
                    preview: responsePreview(data)
                )
            }

            return HubcapLibraryPage(
                totalCount: payload.totalCount,
                games: payload.games
            )
        } catch let error as HubcapClientError {
            throw error
        } catch {
            throw HubcapClientError.invalidResponse(
                endpoint: "/api/v1/library",
                preview: responsePreview(data)
            )
        }
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw HubcapClientError.http(-1)
        }

        switch http.statusCode {
        case 200...299:
            return
        case 401, 403:
            throw HubcapClientError.unauthorized
        case 404:
            throw HubcapClientError.unavailable
        case 429:
            throw HubcapClientError.rateLimited
        default:
            throw HubcapClientError.http(http.statusCode)
        }
    }
}
