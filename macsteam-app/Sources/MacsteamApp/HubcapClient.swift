import Foundation

enum HubcapClientError: LocalizedError {
    case invalidAPIKey
    case invalidAppID
    case unauthorized
    case rateLimited
    case unavailable
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "Hubcap rejected the API key. Sign in with Discord on Hubcap and generate a new key."
        case .invalidAppID:
            return "Enter a valid Steam App ID."
        case .unauthorized:
            return "Hubcap requires Discord-authorized access. Check the API key saved in macSteam."
        case .rateLimited:
            return "Hubcap's download limit for this key has been reached. Try again later or use another authorized key."
        case .unavailable:
            return "Hubcap doesn't have a manifest for this App ID."
        case .http(let status):
            return "Hubcap returned HTTP \(status)."
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

    func checkStatus(appID: Int, apiKey: String) async throws {
        let request = try makeRequest(path: "/api/v1/status/\(appID)", apiKey: apiKey)
        let (_, response) = try await session.data(for: request)
        try validate(response, allowNotFound: true)
    }

    func downloadManifestZip(appID: Int, apiKey: String) async throws -> URL {
        let request = try makeRequest(path: "/api/v1/manifest/\(appID)", apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        try validate(response)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hubcap-\(appID)-\(UUID().uuidString).zip")
        try data.write(to: tempURL, options: .atomic)
        return tempURL
    }

    private func makeRequest(path: String, apiKey: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("smm_"), key.count >= 20 else {
            throw HubcapClientError.invalidAPIKey
        }
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw HubcapClientError.http(-1)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60
        return request
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
