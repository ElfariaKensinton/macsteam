import AppKit

@MainActor
final class HubcapViewController: NSViewController {
    let store: ConfigStore
    let onConfigChanged: () -> Void

    private let client = HubcapClient()
    private let keychainAccount = "hubcap-api-key"

    private var apiKeyField: NSSecureTextField!
    private var saveKeyButton: NSButton!
    private var forgetKeyButton: NSButton!
    private var openHubcapButton: NSButton!

    private var searchField: NSSearchField!
    private var searchButton: NSButton!
    private var clearSearchButton: NSButton!
    private var refreshButton: NSButton!
    private var tableView: NSTableView!
    private var statusLabel: NSTextField!
    private var spinner: NSProgressIndicator!
    private var emptyLabel: NSTextField!

    private var games: [HubcapGame] = []
    private var totalCount = 0
    private var isBusy = false

    init(store: ConfigStore, onConfigChanged: @escaping () -> Void) {
        self.store = store
        self.onConfigChanged = onConfigChanged
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 560))
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Hubcap")
        title.font = Typography.largeTitle
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString:
            "Browse every game in Hubcap, search by name or App ID, and install its Lua manifest."
        )
        subtitle.font = Typography.body
        subtitle.textColor = Colors.secondaryText
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 0
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let authHeader = settingsGroupLabel("Authentication")
        let authCopy = NSTextField(labelWithString:
            "Discord sign-in is the separate Hubcap website account flow. Native API access uses the "
            + "API key generated for that account; macSteam stores only that API key in Keychain."
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
            apiKeyField.widthAnchor.constraint(equalToConstant: 260),

            authButtons.leadingAnchor.constraint(equalTo: apiKeyField.trailingAnchor, constant: 12),
            authButtons.trailingAnchor.constraint(lessThanOrEqualTo: authCard.trailingAnchor, constant: -14),
            authButtons.centerYAnchor.constraint(equalTo: apiKeyField.centerYAnchor),
            authButtons.bottomAnchor.constraint(equalTo: authCard.bottomAnchor, constant: -14),
        ])

        let libraryHeader = settingsGroupLabel("Games")

        searchField = NSSearchField()
        searchField.placeholderString = "Search by game name or App ID"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityLabel("Search Hubcap games")
        searchField.target = self
        searchField.action = #selector(searchFieldSubmitted)

        searchButton = makeButton(title: "Search", target: self, action: #selector(search))
        clearSearchButton = makeButton(title: "Clear", target: self, action: #selector(clearSearch))
        refreshButton = makeButton(title: "Refresh", target: self, action: #selector(refreshLibrary))

        let searchRow = NSStackView(views: [searchField, searchButton, clearSearchButton, refreshButton])
        searchRow.orientation = .horizontal
        searchRow.alignment = .centerY
        searchRow.spacing = 8
        searchRow.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = 48
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .inset

        let gameColumn = NSTableColumn(identifier: .init("game"))
        gameColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(gameColumn)

        let scroll = makeScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = tableView

        emptyLabel = NSTextField(labelWithString: "No games found.")
        emptyLabel.font = Typography.body
        emptyLabel.textColor = Colors.secondaryText
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let tableContainer = NSView()
        tableContainer.translatesAutoresizingMaskIntoConstraints = false
        tableContainer.applyCardSurface()
        tableContainer.addSubview(scroll)
        tableContainer.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: tableContainer.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: tableContainer.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: tableContainer.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: tableContainer.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: tableContainer.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableContainer.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: tableContainer.leadingAnchor, constant: 20),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: tableContainer.trailingAnchor, constant: -20),
        ])

        statusLabel = NSTextField(labelWithString: "Loading Hubcap library…")
        statusLabel.font = Typography.caption
        statusLabel.textColor = Colors.secondaryText
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [
            title, subtitle, authHeader, authCard, libraryHeader,
            searchRow, tableContainer, statusRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: subtitle)
        stack.setCustomSpacing(6, after: authHeader)
        stack.setCustomSpacing(18, after: authCard)
        stack.setCustomSpacing(6, after: libraryHeader)
        stack.setCustomSpacing(8, after: searchRow)
        stack.setCustomSpacing(8, after: tableContainer)
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stack)

        let m = Metrics.paneMargin
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: m),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -m),

            authCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            searchRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tableContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tableContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        apiKeyField.stringValue = KeychainStore.read(account: keychainAccount) ?? ""
        emptyLabel.isHidden = true
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        apiKeyField.stringValue = KeychainStore.read(account: keychainAccount) ?? ""
        guard !apiKeyField.stringValue.isEmpty else {
            setStatus("Open Hubcap with Discord, create an API key, and save it here.", tone: .neutral)
            return
        }
        if games.isEmpty {
            loadLibrary()
        }
    }

    @objc private func openHubcap() {
        NSWorkspace.shared.open(HubcapClient.hubcapURL)
    }

    @objc private func saveKey() {
        do {
            let key = try validatedKey()
            try KeychainStore.write(key, account: keychainAccount)
            setStatus("Hubcap API key saved. Loading library…", tone: .ok)
            loadLibrary()
        } catch {
            setStatus(error.localizedDescription, tone: .bad)
        }
    }

    @objc private func forgetKey() {
        do {
            try KeychainStore.delete(account: keychainAccount)
            apiKeyField.stringValue = ""
            games.removeAll()
            totalCount = 0
            tableView.reloadData()
            emptyLabel.isHidden = false
            setStatus("Hubcap API key removed.", tone: .neutral)
        } catch {
            setStatus(error.localizedDescription, tone: .bad)
        }
    }

    @objc private func searchFieldSubmitted() {
        search()
    }

    @objc private func search() {
        guard !isBusy else { return }
        guard currentKey() != nil else { return }

        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            loadLibrary()
            return
        }
        guard query.count >= 3 else {
            setStatus("Search requires at least 3 characters.", tone: .bad)
            return
        }

        guard let key = currentKey() else { return }
        setBusy(true, status: "Searching Hubcap…")

        Task {
            do {
                let page = try await client.search(query: query, apiKey: key)
                games = page.games.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                totalCount = page.totalCount
                updateList()
                setBusy(false)
                let noun = games.count == 1 ? "game" : "games"
                setStatus("Found (games.count) (noun) for “(query)”.", tone: .ok)
            } catch {
                setBusy(false)
                setStatus(error.localizedDescription, tone: .bad)
            }
        }
    }

    @objc private func clearSearch() {
        searchField.stringValue = ""
        loadLibrary()
    }

    @objc private func refreshLibrary() {
        guard !isBusy else { return }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            loadLibrary()
        } else {
            search()
        }
    }

    private func loadLibrary() {
        guard !isBusy else { return }
        guard let key = currentKey() else { return }

        setBusy(true, status: "Loading Hubcap library…")
        Task {
            do {
                var loaded: [HubcapGame] = []
                var offset = 0
                var total = 0

                repeat {
                    let page = try await client.libraryPage(apiKey: key, limit: 100, offset: offset)
                    loaded.append(contentsOf: page.games)
                    total = page.totalCount
                    offset += page.games.count
                } while !loaded.isEmpty && offset < total

                games = loaded.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                totalCount = total > 0 ? total : games.count

                updateList()
                setBusy(false)
                setStatus("\(games.count) games available in Hubcap.", tone: .ok)
            } catch {
                setBusy(false)
                setStatus(error.localizedDescription, tone: .bad)
            }
        }
    }

    private func install(game: HubcapGame) {
        guard !isBusy, let appID = game.appID, let key = currentKey() else { return }

        setBusy(true, status: "Downloading Lua for \(game.name)…")
        Task {
            var luaURL: URL?
            do {
                luaURL = try await client.downloadLua(appID: appID, apiKey: key)
                guard let luaURL else { throw HubcapInstallError.downloadEmpty }

                setStatus("Installing \(game.name)…", tone: .neutral)
                let plan = try await Task.detached(priority: .userInitiated) {
                    try ZipImporter.buildPlan(fromLua: luaURL)
                }.value

                guard plan.mainAppID == appID else {
                    throw HubcapInstallError.appIDMismatch(requested: appID)
                }

                try store.mutate { cfg in
                    _ = ZipImporter.merge(plan, into: &cfg)
                }

                onConfigChanged()
                setBusy(false)
                setStatus("Installed \(game.name) into macSteam.", tone: .ok)
            } catch {
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
            if !isBusy { setStatus(error.localizedDescription, tone: .bad) }
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
        searchField.isEnabled = !busy
        searchButton.isEnabled = !busy
        clearSearchButton.isEnabled = !busy
        refreshButton.isEnabled = !busy
        tableView.isEnabled = !busy
        if let status {
            setStatus(status, tone: .neutral)
        }
    }

    private func setStatus(_ text: String, tone: StatusTone) {
        statusLabel.stringValue = text
        statusLabel.textColor = tone.color
    }

    private func updateList() {
        tableView.reloadData()
        emptyLabel.isHidden = !games.isEmpty
        emptyLabel.stringValue = searchField.stringValue.isEmpty
            ? "No games returned by Hubcap."
            : "No games match this search."
    }
}

extension HubcapViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        games.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard row >= 0, row < games.count else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("HubcapGameCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? HubcapGameCell)
            ?? HubcapGameCell(identifier: identifier)

        let game = games[row]
        cell.configure(game: game)
        cell.onInstall = { [weak self] in
            self?.install(game: game)
        }
        return cell
    }

    func tableView(
        _ tableView: NSTableView,
        heightOfRow row: Int
    ) -> CGFloat {
        48
    }
}

@MainActor
private final class HubcapGameCell: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let idLabel = NSTextField(labelWithString: "")
    private let installButton = NSButton(title: "Install", target: nil, action: nil)

    var onInstall: (() -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        nameLabel.font = Typography.body
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        idLabel.font = Typography.caption
        idLabel.textColor = Colors.secondaryText
        idLabel.translatesAutoresizingMaskIntoConstraints = false

        installButton.bezelStyle = .rounded
        installButton.controlSize = .small
        installButton.target = self
        installButton.action = #selector(installPressed)
        installButton.translatesAutoresizingMaskIntoConstraints = false
        installButton.setAccessibilityLabel("Install game")

        addSubview(nameLabel)
        addSubview(idLabel)
        addSubview(installButton)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -7),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: installButton.leadingAnchor, constant: -12),

            idLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            idLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 9),

            installButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            installButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(game: HubcapGame) {
        nameLabel.stringValue = game.name
        idLabel.stringValue = "App ID (game.id)"
        installButton.isEnabled = game.appID != nil
        onInstall = nil
    }

    @objc private func installPressed() {
        onInstall?()
    }
}

private enum HubcapInstallError: LocalizedError {
    case appIDMismatch(requested: Int)
    case downloadEmpty

    var errorDescription: String? {
        switch self {
        case .appIDMismatch(let id):
            return "Hubcap returned Lua that does not contain App \(id)."
        case .downloadEmpty:
            return "Hubcap returned an empty Lua download."
        }
    }
}
