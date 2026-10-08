import AppKit

@MainActor
final class HubcapViewController: NSViewController {
    let store: ConfigStore
    let onConfigChanged: () -> Void

    private let client = HubcapClient()
    private let keychainAccount = "hubcap-api-key"

    private var apiKeyField: NSSecureTextField!
    private var appIDField: NSTextField!
    private var saveKeyButton: NSButton!
    private var forgetKeyButton: NSButton!
    private var checkButton: NSButton!
    private var installButton: NSButton!
    private var openHubcapButton: NSButton!
    private var spinner: NSProgressIndicator!
    private var statusLabel: NSTextField!
    private var statusGlyph: NSImageView!

    private var isBusy = false

    init(store: ConfigStore, onConfigChanged: @escaping () -> Void) {
        self.store = store
        self.onConfigChanged = onConfigChanged
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 560))
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Hubcap")
        title.font = Typography.largeTitle
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString:
            "Download Lua manifests from Hubcap and install them through macSteam's existing parser and config path."
        )
        subtitle.font = Typography.body
        subtitle.textColor = Colors.secondaryText
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 0
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let authHeader = settingsGroupLabel("Authentication")
        let authCopy = NSTextField(labelWithString:
            "Hubcap has two separate paths. Use Discord on the Hubcap website for account access; native API "
            + "downloads use an API key generated from that account. macSteam stores only the API key in Keychain."
        )
        authCopy.font = Typography.caption
        authCopy.textColor = Colors.secondaryText
        authCopy.lineBreakMode = .byWordWrapping
        authCopy.maximumNumberOfLines = 0
        authCopy.translatesAutoresizingMaskIntoConstraints = false

        openHubcapButton = makeButton(
            title: "Open Hubcap with Discord",
            target: self,
            action: #selector(openHubcap)
        )

        apiKeyField = NSSecureTextField()
        apiKeyField.placeholderString = "smm_… API key"
        apiKeyField.translatesAutoresizingMaskIntoConstraints = false
        apiKeyField.setAccessibilityLabel("Hubcap API key")
        apiKeyField.stringValue = KeychainStore.read(account: keychainAccount) ?? ""

        saveKeyButton = makeButton(title: "Save Key", target: self, action: #selector(saveKey))
        forgetKeyButton = makeButton(title: "Forget Key", target: self, action: #selector(forgetKey))

        let authButtons = NSStackView(views: [openHubcapButton, saveKeyButton, forgetKeyButton])
        authButtons.orientation = .horizontal
        authButtons.alignment = .centerY
        authButtons.spacing = 8
        authButtons.translatesAutoresizingMaskIntoConstraints = false

        let authCard = NSView()
        authCard.translatesAutoresizingMaskIntoConstraints = false
        authCard.applyCardSurface()
        authCard.addSubview(authCopy)
        authCard.addSubview(apiKeyField)
        authCard.addSubview(authButtons)

        NSLayoutConstraint.activate([
            authCopy.topAnchor.constraint(equalTo: authCard.topAnchor, constant: 14),
            authCopy.leadingAnchor.constraint(equalTo: authCard.leadingAnchor, constant: 14),
            authCopy.trailingAnchor.constraint(equalTo: authCard.trailingAnchor, constant: -14),

            apiKeyField.topAnchor.constraint(equalTo: authCopy.bottomAnchor, constant: 12),
            apiKeyField.leadingAnchor.constraint(equalTo: authCard.leadingAnchor, constant: 14),
            apiKeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),

            authButtons.leadingAnchor.constraint(equalTo: apiKeyField.trailingAnchor, constant: 12),
            authButtons.trailingAnchor.constraint(lessThanOrEqualTo: authCard.trailingAnchor, constant: -14),
            authButtons.centerYAnchor.constraint(equalTo: apiKeyField.centerYAnchor),
            authButtons.bottomAnchor.constraint(equalTo: authCard.bottomAnchor, constant: -14),
        ])

        let appHeader = settingsGroupLabel("Lua manifest")
        appIDField = NSTextField()
        appIDField.placeholderString = "Steam App ID"
        appIDField.font = Typography.body
        appIDField.controlSize = .regular
        appIDField.alignment = .right
        appIDField.translatesAutoresizingMaskIntoConstraints = false
        appIDField.setAccessibilityLabel("Steam App ID")

        checkButton = makeButton(title: "Check", target: self, action: #selector(checkAvailability))
        installButton = makeButton(title: "Download & Install", target: self, action: #selector(downloadAndInstall))
        installButton.keyEquivalent = "\r"
        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let appRow = NSStackView(views: [appIDField, checkButton, installButton, spinner])
        appRow.orientation = .horizontal
        appRow.alignment = .centerY
        appRow.spacing = 8
        appRow.translatesAutoresizingMaskIntoConstraints = false
        appIDField.widthAnchor.constraint(equalToConstant: 150).isActive = true

        statusGlyph = NSImageView()
        statusGlyph.symbolConfiguration = .init(pointSize: 17, weight: .medium)
        statusGlyph.translatesAutoresizingMaskIntoConstraints = false
        statusGlyph.setAccessibilityElement(false)

        statusLabel = NSTextField(labelWithString: "Enter an App ID to check Hubcap.")
        statusLabel.font = Typography.body
        statusLabel.textColor = Colors.secondaryText
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let statusRow = NSStackView(views: [statusGlyph, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .top
        statusRow.spacing = 8
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        let manifestCard = NSView()
        manifestCard.translatesAutoresizingMaskIntoConstraints = false
        manifestCard.applyCardSurface()
        manifestCard.addSubview(appRow)
        manifestCard.addSubview(statusRow)

        NSLayoutConstraint.activate([
            appRow.topAnchor.constraint(equalTo: manifestCard.topAnchor, constant: 14),
            appRow.leadingAnchor.constraint(equalTo: manifestCard.leadingAnchor, constant: 14),
            appRow.trailingAnchor.constraint(equalTo: manifestCard.trailingAnchor, constant: -14),

            statusRow.topAnchor.constraint(equalTo: appRow.bottomAnchor, constant: 14),
            statusRow.leadingAnchor.constraint(equalTo: manifestCard.leadingAnchor, constant: 14),
            statusRow.trailingAnchor.constraint(equalTo: manifestCard.trailingAnchor, constant: -14),
            statusRow.bottomAnchor.constraint(equalTo: manifestCard.bottomAnchor, constant: -14),

            statusGlyph.widthAnchor.constraint(equalToConstant: 20),
            statusGlyph.heightAnchor.constraint(equalToConstant: 20),
        ])

        let note = NSTextField(labelWithString:
            "The downloaded Lua is processed with the same parser and config merge used by Import Apps. "
            + "For depot .manifest files, use the full Hubcap manifest ZIP through Import Apps."
        )
        note.font = Typography.caption
        note.textColor = Colors.quiet
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 0
        note.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, subtitle, authHeader, authCard, appHeader, manifestCard, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: subtitle)
        stack.setCustomSpacing(6, after: authHeader)
        stack.setCustomSpacing(18, after: authCard)
        stack.setCustomSpacing(6, after: appHeader)
        stack.setCustomSpacing(18, after: manifestCard)
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stack)

        let m = Metrics.paneMargin
        let width = stack.widthAnchor.constraint(equalToConstant: Metrics.formColumnWidth + 60)
        width.priority = .defaultHigh

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: m),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: m),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -m),
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            width,

            authCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            manifestCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        setBusy(false)
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        apiKeyField.stringValue = KeychainStore.read(account: keychainAccount) ?? ""
    }

    @objc private func openHubcap() {
        NSWorkspace.shared.open(HubcapClient.apiKeysURL)
    }

    @objc private func saveKey() {
        do {
            let key = try validatedKey()
            try KeychainStore.write(key, account: keychainAccount)
            setStatus("Hubcap API key saved in Keychain.", tone: .ok)
        } catch {
            setStatus(error.localizedDescription, tone: .bad)
        }
    }

    @objc private func forgetKey() {
        do {
            try KeychainStore.delete(account: keychainAccount)
            apiKeyField.stringValue = ""
            setStatus("Hubcap API key removed.", tone: .neutral)
        } catch {
            setStatus(error.localizedDescription, tone: .bad)
        }
    }

    @objc private func checkAvailability() {
        guard let appID = validatedAppID() else { return }
        guard let key = currentKey() else { return }

        setBusy(true, status: "Checking Hubcap…")
        Task {
            do {
                try await client.checkStatus(appID: appID, apiKey: key)
                setBusy(false)
                setStatus("Hubcap has a manifest for App \(appID).", tone: .ok)
            } catch {
                setBusy(false)
                setStatus(error.localizedDescription, tone: .bad)
            }
        }
    }

    @objc private func downloadAndInstall() {
        guard !isBusy, let appID = validatedAppID(), let key = currentKey() else { return }

        setBusy(true, status: "Downloading Hubcap Lua…")
        Task {
            var luaURL: URL?
            do {
                let downloaded = try await client.downloadLua(appID: appID, apiKey: key)
                luaURL = downloaded
                setStatus("Parsing Lua manifest…", tone: .neutral)

                let plan = try await Task.detached(priority: .userInitiated) {
                    try ZipImporter.buildPlan(fromLua: downloaded)
                }.value

                guard plan.mainAppID == appID else {
                    throw HubcapInstallError.appIDMismatch(requested: appID)
                }

                try store.mutate { cfg in
                    _ = ZipImporter.merge(plan, into: &cfg)
                }

                onConfigChanged()
                setBusy(false)
                let dlcCount = plan.dlcAppIDs.count
                let detail = dlcCount > 0
                    ? "App \\(appID) installed with \\(dlcCount) DLC entries."
                    : "App \\(appID) installed."
                setStatus(detail, tone: .ok)
            } catch {
                if let luaURL { try? FileManager.default.removeItem(at: luaURL) }
                setBusy(false)
                setStatus(error.localizedDescription, tone: .bad)
            }
            if let luaURL { try? FileManager.default.removeItem(at: luaURL) }
        }
    }

    private func currentKey() -> String? {
        do {
            let key = try validatedKey()
            if KeychainStore.read(account: keychainAccount) != key {
                try KeychainStore.write(key, account: keychainAccount)
            }
            return key
        } catch {
            setStatus(error.localizedDescription, tone: .bad)
            return nil
        }
    }

    private func validatedKey() throws -> String {
        let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.range(of: #"^smm_[0-9a-f]{96}$"#, options: .regularExpression) != nil else {
            throw HubcapClientError.invalidAPIKey
        }
        return key
    }

    private func validatedAppID() -> Int? {
        let raw = appIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let appID = Int(raw), appID > 0 else {
            setStatus(HubcapClientError.invalidAppID.localizedDescription, tone: .bad)
            return nil
        }
        return appID
    }

    private func setBusy(_ busy: Bool, status: String? = nil) {
        isBusy = busy
        spinner.isHidden = !busy
        if busy {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        openHubcapButton.isEnabled = !busy
        saveKeyButton.isEnabled = !busy
        forgetKeyButton.isEnabled = !busy
        checkButton.isEnabled = !busy
        installButton.isEnabled = !busy
        if let status {
            self.setStatus(status, tone: .neutral)
        }
    }

    private func setStatus(_ text: String, tone: StatusTone) {
        statusLabel.stringValue = text
        statusGlyph.image = NSImage(
            systemSymbolName: tone.symbol,
            accessibilityDescription: nil
        )
        statusGlyph.contentTintColor = tone.color
    }
}

private enum HubcapInstallError: LocalizedError {
    case appIDMismatch(requested: Int)

    var errorDescription: String? {
        switch self {
        case .appIDMismatch(let id):
            return "Hubcap returned a package that does not contain App \(id)."
        }
    }
}
