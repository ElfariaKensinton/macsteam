import Foundation

enum HubcapCredentialStore {
    private static let keychainAccount = "api-key"
    private static let legacyDefaultsKey = "hubcap.apiKey"

    static var apiKey: String? {
        if let key = KeychainStore.read(account: keychainAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            return key
        }

        guard let legacy = UserDefaults.standard.string(forKey: legacyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !legacy.isEmpty
        else {
            return nil
        }

        // Migrate the old insecure UserDefaults value once. If keychain access fails,
        // keep returning the legacy value so an existing user is not silently logged out.
        if (try? KeychainStore.write(legacy, account: keychainAccount)) != nil {
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        }
        return legacy
    }

    static func save(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        try KeychainStore.write(key, account: keychainAccount)
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
    }

    static func remove() throws {
        try KeychainStore.delete(account: keychainAccount)
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
    }
}
