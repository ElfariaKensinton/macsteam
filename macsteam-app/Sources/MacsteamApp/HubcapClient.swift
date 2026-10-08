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
    case invalidResponse(endpoint: String)

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
            return "Hubcap returned an unexpected response from \(endpoint)."
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

    func allGames(apiKey: String) async throws -> [HubcapGame] {
        let request = try makeRequest(
            url: baseURL.appendingPathComponent("/api/v1/games"),
            apiKey: apiKey,
            accept: "application/json"
        )
        let (data, response) = try await session.data(for: request)
        try validate(response)

        let object = try JSONSerialization.jsonObject(with: data)
        if let items = object as? [[String: Any]] {
            return decodeGames(items)
        }

        guard let root = object as? [String: Any] else {
            throw HubcapClientError.invalidResponse(endpoint: "/api/v1/games")
        }

        let items =
            (root["games"] as? [[String: Any]])
            ?? (root["items"] as? [[String: Any]])
            ?? (root["results"] as? [[String: Any]])

        guard let items else {
            throw HubcapClientError.invalidResponse(endpoint: "/api/v1/games")
        }

        return decodeGames(items)
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
        return try decodeLibraryPage(data)
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
        let object = try JSONSerialization.jsonObject(with: data)

        if let array = object as? [[String: Any]] {
            let games = decodeGames(array)
            guard !games.isEmpty || array.isEmpty else {
                throw HubcapClientError.invalidResponse
            }
            return HubcapLibraryPage(totalCount: games.count, games: games)
        }

        guard let root = object as? [String: Any] else {
            throw HubcapClientError.invalidResponse
        }

        let payloads = candidateDictionaries(from: root)
        for payload in payloads {
            if let gamesValue = firstValue(in: payload, keys: ["games", "items", "results"]) {
                let games = decodeGamesValue(gamesValue)
                let total = intValue(payload["total_count"])
                    ?? intValue(payload["total"])
                    ?? intValue(payload["count"])

                if !games.isEmpty || total == 0 || total == nil {
                    return HubcapLibraryPage(
                        totalCount: total ?? games.count,
                        games: games
                    )
                }

                throw HubcapClientError.invalidResponse
            }
        }

        throw HubcapClientError.invalidResponse
    }

    private func candidateDictionaries(from root: [String: Any]) -> [[String: Any]] {
        var candidates: [[String: Any]] = [root]

        if let data = root["data"] as? [String: Any] {
            candidates.append(contentsOf: candidateDictionaries(from: data))
        }
        if let result = root["result"] as? [String: Any] {
            candidates.append(contentsOf: candidateDictionaries(from: result))
        }

        return candidates
    }

    private func firstValue(in dictionary: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = dictionary[key] {
                return value
            }
        }
        return nil
    }

    private func decodeGamesValue(_ value: Any) -> [HubcapGame] {
        if let items = value as? [[String: Any]] {
            return decodeGames(items)
        }

        if let map = value as? [String: Any] {
            var games: [HubcapGame] = []

            for (key, rawValue) in map {
                if let name = stringValue(rawValue) {
                    games.append(HubcapGame(id: key, name: name))
                    continue
                }

                if let item = rawValue as? [String: Any] {
                    let itemWithFallbackID: [String: Any]
                    if item["app_id"] == nil && item["game_id"] == nil &&
                       item["appid"] == nil && item["gameid"] == nil {
                        itemWithFallbackID = item.merging(["app_id": key]) { current, _ in current }
                    } else {
                        itemWithFallbackID = item
                    }

                    if let game = decodeGame(itemWithFallbackID) {
                        games.append(game)
                    }
                }
            }

            return games
        }

        return []
    }

    private func decodeGames(_ items: [[String: Any]]) -> [HubcapGame] {
        items.compactMap(decodeGame)
    }

    private func decodeGame(_ item: [String: Any]) -> HubcapGame? {
        let rawID =
            stringValue(item["app_id"])
            ?? stringValue(item["game_id"])
            ?? stringValue(item["appid"])
            ?? stringValue(item["gameid"])
            ?? stringValue(item["id"])

        let name =
            stringValue(item["game_name"])
            ?? stringValue(item["name"])
            ?? stringValue(item["title"])
            ?? stringValue(item["display_name"])
            ?? stringValue(item["game"])

        guard let rawID, let name, !rawID.isEmpty, !name.isEmpty else {
            return nil
        }

        return HubcapGame(id: rawID, name: name)
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

    private func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
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
