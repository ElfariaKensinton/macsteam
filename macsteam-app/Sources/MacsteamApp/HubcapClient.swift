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

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "Hubcap rejected the API key. Sign in on the Hubcap website with Discord and generate a new key."
        case .invalidSearch:
            return "Enter at least 3 characters to search Hubcap."
        case .unauthorized:
            return "The Hubcap API requires the API key generated for your Hubcap account. Discord sign-in is the separate website account flow."
        case .rateLimited:
            return "Hubcap's download limit for this key has been reached. Try again later or use another authorized key."
        case .unavailable:
            return "Hubcap doesn't have a Lua manifest for this game."
        case .http(let status):
            return "Hubcap returned HTTP \(status)."
        }
    }
}

final class HubcapClient: @unchecked Sendable {
    static let hubcapURL = URL(string: "https://hubcapmanifest.com/")!

    private let session: URLSession
    private let baseURL = URL(string: "https://hubcapmanifest.com")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func libraryPage(apiKey: String, limit: Int = 100, offset: Int = 0) async throws -> HubcapLibraryPage {
        var components = URLComponents(url: baseURL.appendingPathComponent("/api/v1/library"),
                                        resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100))),
            URLQueryItem(name: "offset", value: String(max(offset, 0))),
            URLQueryItem(name: "sort_by", value: "name"),
        ]
        let request = try makeRequest(url: components.url!, apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try decodeLibraryPage(data)
    }

    func search(query: String, apiKey: String) async throws -> HubcapLibraryPage {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 3 else { throw HubcapClientError.invalidSearch }

        var components = URLComponents(url: baseURL.appendingPathComponent("/api/v1/search"),
                                        resolvingAgainstBaseURL: false)!
        let isAppID = q.allSatisfy(\.isNumber)
        components.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "appid", value: isAppID ? "true" : "false"),
        ]
        let request = try makeRequest(url: components.url!, apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try decodeLibraryPage(data)
    }

    func checkStatus(appID: Int, apiKey: String) async throws {
        let request = try makeRequest(url: baseURL.appendingPathComponent("/api/v1/status/\(appID)"), apiKey: apiKey)
        let (_, response) = try await session.data(for: request)
        try validate(response, allowNotFound: true)
    }

    func downloadLua(appID: Int, apiKey: String) async throws -> URL {
        let request = try makeRequest(path: "/api/v1/lua/\\(appID)", apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        try validate(response)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hubcap-\\(appID)-\\(UUID().uuidString).lua")
        try data.write(to: tempURL, options: .atomic)
        return tempURL
    }

    private func makeRequest(url: URL, apiKey: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.range(of: #"^smm_[0-9a-f]{96}$"#, options: .regularExpression) != nil else {
            throw HubcapClientError.invalidAPIKey
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60
        return request
    }

    private func decodeLibraryPage(_ data: Data) throws -> HubcapLibraryPage {
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let total = (raw["total_count"] as? Int) ?? 0
        let items = (raw["games"] as? [[String: Any]] ?? []).compactMap { item -> HubcapGame? in
            let rawID = (item["game_id"] as? String)
                ?? (item["app_id"] as? String)
                ?? (item["game_id"] as? Int).map(String.init)
                ?? (item["app_id"] as? Int).map(String.init)
            let name = (item["game_name"] as? String)
                ?? (item["name"] as? String)
            guard let rawID, let name, !rawID.isEmpty, !name.isEmpty else { return nil }
            return HubcapGame(id: rawID, name: name)
        }
        return HubcapLibraryPage(totalCount: total == 0 ? items.count : total, games: items)
    }

    private func validate(_ response: URLResponse, allowNotFound: Bool = false) throws {
        guard let http = response as? HTTPURLResponse else {
            throw HubcapClientError.http(-1)
        }

        switch http.statusCode {
        case 200...299:
            return
        case 401, 403:
            throw HubcapClientError.unauthorized
        case 404 where allowNotFound:
            throw HubcapClientError.unavailable
        case 404:
            throw HubcapClientError.unavailable
        case 429:
            throw HubcapClientError.rateLimited
        default:
            throw HubcapClientError.http(http.statusCode)
        }
    }
}
