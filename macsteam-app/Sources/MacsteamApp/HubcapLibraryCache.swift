import Foundation

struct HubcapLibrarySnapshot: Codable, Sendable {
    let updatedAt: Date
    let totalCount: Int
    let games: [HubcapGame]
}

actor HubcapLibraryCache {
    private let fileURL: URL

    init(fileURL: URL = Paths.configDir.appendingPathComponent("hubcap-library.json")) {
        self.fileURL = fileURL
    }

    func load() -> HubcapLibrarySnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(HubcapLibrarySnapshot.self, from: data)
    }

    func save(_ snapshot: HubcapLibrarySnapshot) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    func remove() throws {
        try FileManager.default.removeItem(at: fileURL)
    }
}
