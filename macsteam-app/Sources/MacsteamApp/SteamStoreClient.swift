// Steam store name/art resolver
import AppKit
import CryptoKit
import Foundation

struct StoreAppInfo: Sendable, Equatable, Codable {
    let name: String
    let headerURL: String?
    var isDLC: Bool = false
    var parentAppID: Int? = nil
}

actor SteamStoreClient {
    static let shared = SteamStoreClient()

    private static let metadataTTL: TimeInterval = 7 * 24 * 60 * 60
    private static let imageTTL: TimeInterval = 60 * 24 * 60 * 60
    private static let imageCacheCap = 5 << 20

    private struct MetaRecord: Codable {
        let info: StoreAppInfo
        let fetchedAt: Date
    }

    private var metaCache: [Int: MetaRecord] = [:]
    private var metaLoaded = false

    private var inFlightImages: [String: Task<Data?, Never>] = [:]

    private let session: URLSession
    private let artworkDir: URL
    private let metaFile: URL

    private static let allowedHostSuffixes = [
        ".steamstatic.com",
        ".steampowered.com",
        ".steamcdn-a.akamaihd.net",
    ]

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .useProtocolCachePolicy
        cfg.urlCache = URLCache(memoryCapacity: 4 << 20, diskCapacity: 32 << 20, directory: nil)
        cfg.timeoutIntervalForRequest = 15
        session = URLSession(configuration: cfg)

        artworkDir = Paths.configDir.appendingPathComponent("artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: artworkDir, withIntermediateDirectories: true)
        metaFile = artworkDir.appendingPathComponent("metadata.json")

        Self.pruneImageCache(in: artworkDir)
    }

    // MARK: - Metadata persistence

    private func loadMetaCacheIfNeeded() {
        guard !metaLoaded else { return }
        metaLoaded = true
        guard let data = try? Data(contentsOf: metaFile),
              let decoded = try? JSONDecoder().decode([Int: MetaRecord].self, from: data) else { return }
        metaCache = decoded
    }

    private func saveMetaCache() {
        guard let data = try? JSONEncoder().encode(metaCache) else { return }
        Self.writeAtomically(data, to: metaFile)
    }

    // MARK: - Name + header resolution

    func resolve(appIDs: [Int]) async -> [Int: StoreAppInfo] {
        let wanted = Set(appIDs.filter { $0 > 0 })
        guard !wanted.isEmpty else { return [:] }

        loadMetaCacheIfNeeded()
        let now = Date()
        var result: [Int: StoreAppInfo] = [:]
        var missing: [Int] = []
        for id in wanted {
            if let rec = metaCache[id], now.timeIntervalSince(rec.fetchedAt) < Self.metadataTTL {
                result[id] = rec.info
            } else {
                missing.append(id)
            }
        }
        guard !missing.isEmpty else { return result }

        guard let url = Self.getItemsURL(for: missing) else { return result }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return result }
            for (id, info) in Self.parseGetItems(data) {
                metaCache[id] = MetaRecord(info: info, fetchedAt: now)
                result[id] = info
            }
            saveMetaCache()
        } catch {}
        return result
    }

    private static func getItemsURL(for appIDs: [Int]) -> URL? {
        let ids = appIDs.map { ["appid": $0] }
        let payload: [String: Any] = [
            "ids": ids,
            "context": ["language": "english", "country_code": "US"],
            "data_request": ["include_basic_info": true, "include_assets": true],
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: json, encoding: .utf8) else { return nil }

        var comps = URLComponents(string: "https://api.steampowered.com/IStoreBrowseService/GetItems/v1")
        comps?.queryItems = [URLQueryItem(name: "input_json", value: jsonString)]
        return comps?.url
    }

    private static func parseGetItems(_ data: Data) -> [Int: StoreAppInfo] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let items = response["store_items"] as? [[String: Any]] else { return [:] }

        var out: [Int: StoreAppInfo] = [:]
        for item in items {
            guard let appid = item["appid"] as? Int else { continue }
            let name = (item["name"] as? String) ?? ""
            var header: String?
            if let assets = item["assets"] as? [String: Any],
               let h = assets["header"] as? String, !h.isEmpty {
                header = "https://shared.steamstatic.com/store_item_assets/steam/apps/\(appid)/\(h)"
            }
            if name.isEmpty && header == nil { continue }
            let isDLC = (item["type"] as? Int) == 4
            var parent: Int?
            if let related = item["related_items"] as? [String: Any] {
                parent = related["parent_appid"] as? Int
            }
            out[appid] = StoreAppInfo(name: name, headerURL: header, isDLC: isDLC, parentAppID: parent)
        }
        return out
    }

    // MARK: - Header images

    func imageData(for headerURL: String?) async -> Data? {
        guard let headerURL, Self.isAllowed(headerURL), let remote = URL(string: headerURL) else {
            return nil
        }

        let cacheFile = artworkDir.appendingPathComponent(Self.cacheKey(headerURL) + ".jpg")
        if let data = try? Data(contentsOf: cacheFile) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cacheFile.path)
            return data
        }

        if let existing = inFlightImages[headerURL] { return await existing.value }

        let task = Task<Data?, Never> { [session] in
            do {
                let (data, response) = try await session.data(from: remote)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      !data.isEmpty else { return nil }
                Self.writeAtomically(data, to: cacheFile)
                return data
            } catch {
                return nil
            }
        }
        inFlightImages[headerURL] = task
        let data = await task.value
        inFlightImages[headerURL] = nil
        return data
    }

    // MARK: - Helpers

    static func isAllowed(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        return allowedHostSuffixes.contains { host == String($0.dropFirst()) || host.hasSuffix($0) }
    }

    private static func cacheKey(_ urlString: String) -> String {
        let digest = SHA256.hash(data: Data(urlString.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func writeAtomically(_ data: Data, to url: URL) {
        try? data.write(to: url, options: .atomic)
    }

    private static func pruneImageCache(in dir: URL) {
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys, options: .skipsHiddenFiles) else { return }

            struct Item { let url: URL; let mtime: Date; let size: Int }
            let now = Date()
            var items: [Item] = []
            for url in entries where url.pathExtension == "jpg" {
                guard let vals = try? url.resourceValues(forKeys: Set(keys)),
                      vals.isRegularFile == true else { continue }
                let mtime = vals.contentModificationDate ?? .distantPast
                let size = vals.fileSize ?? 0
                if now.timeIntervalSince(mtime) > Self.imageTTL {
                    try? fm.removeItem(at: url)
                } else {
                    items.append(Item(url: url, mtime: mtime, size: size))
                }
            }

            var total = items.reduce(0) { $0 + $1.size }
            guard total > Self.imageCacheCap else { return }
            for item in items.sorted(by: { $0.mtime < $1.mtime }) {
                try? fm.removeItem(at: item.url)
                total -= item.size
                if total <= Self.imageCacheCap { break }
            }
        }
    }
}

@MainActor
final class StoreArtLoader {
    private var resolved: [Int: StoreAppInfo] = [:]
    private var images: [Int: NSImage] = [:]
    private var loadingImages: Set<Int> = []

    func name(for appID: Int) -> String? {
        let n = resolved[appID]?.name
        return (n?.isEmpty == false) ? n : nil
    }

    func image(for appID: Int) -> NSImage? { images[appID] }

    private func loadImage(appID: Int, headerURL: String?, targetWidth: CGFloat,
                           onImage: @escaping (Int, NSImage) -> Void) {
        guard headerURL != nil, images[appID] == nil,
              loadingImages.insert(appID).inserted else { return }
        Task { [weak self] in
            let data = await SteamStoreClient.shared.imageData(for: headerURL)
            guard let self else { return }
            self.loadingImages.remove(appID)
            guard let data else { return }
            let img = targetWidth > 0 ? Self.decode(data, targetWidth: targetWidth)
                                      : NSImage(data: data)
            guard let img else { return }
            self.images[appID] = img
            onImage(appID, img)
        }
    }

    func load(_ appIDs: [Int], artWidth: CGFloat,
              onName: @escaping (Int, String) -> Void,
              onArt: @escaping (Int, NSImage) -> Void) {
        let ids = appIDs.filter { $0 > 0 }
        guard !ids.isEmpty else { return }
        for id in ids {
            if let n = name(for: id) { onName(id, n) }
            if let img = image(for: id) { onArt(id, img) }
            if let info = resolved[id] {
                loadImage(appID: id, headerURL: info.headerURL,
                          targetWidth: artWidth, onImage: onArt)
            }
        }
        let need = ids.filter { resolved[$0] == nil }
        guard !need.isEmpty else { return }
        Task { [weak self] in
            let infos = await SteamStoreClient.shared.resolve(appIDs: need)
            guard let self else { return }
            for (id, info) in infos {
                self.resolved[id] = info
                if !info.name.isEmpty { onName(id, info.name) }
            }
            for (id, info) in infos {
                self.loadImage(appID: id, headerURL: info.headerURL,
                               targetWidth: artWidth, onImage: onArt)
            }
        }
    }

    static func decode(_ data: Data, targetWidth: CGFloat) -> NSImage? {
        guard let src = NSBitmapImageRep(data: data) else { return NSImage(data: data) }
        let scale = targetWidth / CGFloat(src.pixelsWide)
        guard scale < 1 else {
            let img = NSImage(size: NSSize(width: src.pixelsWide, height: src.pixelsHigh))
            img.addRepresentation(src)
            return img
        }
        let size = NSSize(width: targetWidth, height: CGFloat(src.pixelsHigh) * scale)
        let img = NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            src.draw(in: rect)
            return true
        }
        return img
    }
}
