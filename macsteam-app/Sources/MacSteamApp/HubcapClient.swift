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
        return try decodeLibraryPage(data)
    }

    func downloadLuaText(appID: Int, apiKey: String) async throws -> String {
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

        // Hubcap returns the Lua script as the response body. Decode the body directly instead of
        // round-tripping it through a temporary .lua file and Foundation's file-format detection.
        var text = String(decoding: data, as: UTF8.self)
        if text.unicodeScalars.first == "\u{FEFF}" {
            text.removeFirst()
        }

        guard LuaManifestParser.containsAddApp(text) else {
            throw HubcapClientError.invalidLuaResponse(appID: appID, preview: preview(of: text))
        }

        return text
    }

    private func preview(of text: String) -> String {
        let compact = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(compact.prefix(120))
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
        request.setValue("macSteam Hubcap Client", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        return request
    }

    private func decodeLibraryPage(_ data: Data) throws -> HubcapLibraryPage {
        let object: Any
        do {
            object = try jsonObject(from: data)
        } catch {
            throw HubcapClientError.invalidResponse(
                endpoint: "/api/v1/library",
                preview: responsePreview(data)
            )
        }

        let dictionaries = candidateDictionaries(from: object)
        for payload in dictionaries {
            let total =
                intValue(payload["total_count"])
                ?? intValue(payload["total"])
                ?? intValue(payload["count"])

            for key in ["games", "items", "results", "data"] {
                guard let value = payload[key] else { continue }
                let games = decodeGamesValue(value)
                if !games.isEmpty || (total == 0) {
                    return HubcapLibraryPage(
                        totalCount: total ?? games.count,
                        games: games
                    )
                }
            }
        }

        // Some deployments return the game collection itself under the top-level
        // "data" field, while others put it directly at the root.
        let directGames = decodeGamesValue(object)
        if !directGames.isEmpty {
            return HubcapLibraryPage(
                totalCount: directGames.count,
                games: directGames
            )
        }

        throw HubcapClientError.invalidResponse(
            endpoint: "/api/v1/library",
            preview: responsePreview(data)
        )
    }

    private func candidateDictionaries(from object: Any) -> [[String: Any]] {
        var candidates: [[String: Any]] = []

        guard let root = object as? [String: Any] else {
            return candidates
        }

        var queue: [[String: Any]] = [root]
        while let current = queue.first {
            queue.removeFirst()
            candidates.append(current)

            for key in ["data", "result", "payload", "response"] {
                if let nested = current[key] as? [String: Any] {
                    queue.append(nested)
                }
            }
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

        if let dictionary = value as? [String: Any] {
            if let game = decodeGame(dictionary) {
                return [game]
            }

            for key in ["games", "items", "results", "data"] {
                if let nested = dictionary[key] {
                    let games = decodeGamesValue(nested)
                    if !games.isEmpty {
                        return games
                    }
                }
            }

            // Accept a map keyed by App ID: {"400": {"game_name": "Portal"}} or
            // {"400": "Portal"}.
            var games: [HubcapGame] = []
            for (key, rawValue) in dictionary {
                if let name = stringValue(rawValue) {
                    games.append(HubcapGame(id: key, name: name))
                    continue
                }

                if let item = rawValue as? [String: Any] {
                    var itemWithFallbackID = item
                    if itemWithFallbackID["app_id"] == nil &&
                       itemWithFallbackID["game_id"] == nil &&
                       itemWithFallbackID["appid"] == nil &&
                       itemWithFallbackID["gameid"] == nil &&
                       itemWithFallbackID["id"] == nil {
                        itemWithFallbackID["app_id"] = key
                    }

                    if let game = decodeGame(itemWithFallbackID) {
                        games.append(game)
                    }
                }
            }
            return games
        }

        if let array = value as? [Any] {
            return array.flatMap { decodeGamesValue($0) }
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

    private func jsonObject(from data: Data) throws -> Any {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes.removeFirst(3)
        }
        return try JSONSerialization.jsonObject(with: bytes)
    }

    private func responsePreview(_ data: Data) -> String {
        let text = String(decoding: data.prefix(240), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "<empty body>" : text
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
