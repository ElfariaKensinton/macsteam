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

struct HubcapUserStats: Sendable {
    let dailyUsage: Int?
    let dailyLimit: Int?
    let canMakeRequests: Bool
}

enum HubcapClientError: LocalizedError {
    case invalidAPIKey
    case invalidSearch
    case unauthorized
    case rateLimited
    case unavailable
    case http(Int)
    case invalidResponse

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
        case .invalidResponse:
            return "Hubcap returned an unexpected response."
        }
    }
}

final class HubcapClient: @unchecked Sendable {
    static let apiKeysURL = URL(string: "https://hubcapmanifest.com/api-keys/")!

    private let session: URLSession
    private let baseURL = URL(string: "https://hubcapmanifest.com")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func libraryPage(apiKey: String, limit: Int = 100, offset: Int = 0) async throws -> HubcapLibraryPage {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/v1/library"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100))),
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
        return try decodeLibraryPage(data)
    }

    func userStats(apiKey: String) async throws -> HubcapUserStats {
        let request = try makeRequest(
            url: baseURL.appendingPathComponent("/api/v1/user/stats"),
            apiKey: apiKey,
            accept: "application/json"
        )
        let (data, response) = try await session.data(for: request)
        try validate(response)

        guard
            let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let canMakeRequests = raw["can_make_requests"] as? Bool
        else {
            throw HubcapClientError.invalidResponse
        }

        return HubcapUserStats(
            dailyUsage: raw["daily_usage"] as? Int,
            dailyLimit: raw["daily_limit"] as? Int,
            canMakeRequests: canMakeRequests
        )
    }

    func downloadLua(appID: Int, apiKey: String) async throws -> URL {
        let request = try makeRequest(
            url: baseURL.appendingPathComponent("/api/v1/lua/\(appID)"),
            apiKey: apiKey,
            accept: "text/plain"
        )
        let (data, response) = try await session.data(for: request)
        try validate(response)

        guard !data.isEmpty else {
            throw HubcapClientError.unavailable
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hubcap-\(appID)-\(UUID().uuidString).lua")
        try data.write(to: tempURL, options: .atomic)
        return tempURL
    }

    private func makeRequest(url: URL, apiKey: String, accept: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.range(
            of: #"^smm_[0-9a-f]{96}$"#,
            options: .regularExpression
        ) != nil else {
            throw HubcapClientError.invalidAPIKey
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60
        return request
    }

    private func decodeLibraryPage(_ data: Data) throws -> HubcapLibraryPage {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HubcapClientError.invalidResponse
        }

        let total = intValue(raw["total_count"]) ?? 0
        let items = (raw["games"] as? [[String: Any]] ?? []).compactMap { item -> HubcapGame? in
            let rawID =
                stringValue(item["game_id"])
                ?? stringValue(item["app_id"])
            let name =
                stringValue(item["game_name"])
                ?? stringValue(item["name"])

            guard
                let rawID,
                let name,
                !rawID.isEmpty,
                !name.isEmpty
            else {
                return nil
            }

            return HubcapGame(id: rawID, name: name)
        }

        return HubcapLibraryPage(
            totalCount: total > 0 ? total : items.count,
            games: items
        )
    }

    private func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            return value
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
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
