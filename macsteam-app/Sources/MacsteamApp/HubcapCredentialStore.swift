import Foundation

enum HubcapCredentialStore {
    private static let key = "hubcap.apiKey"

    static var apiKey: String? {
        let value = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static func save(_ value: String) {
        UserDefaults.standard.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: key)
    }

    static func remove() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
