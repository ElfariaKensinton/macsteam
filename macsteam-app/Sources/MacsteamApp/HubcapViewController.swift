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
    private var apiKeysButton: NSButton!

    private var searchField: NSSearchField!
    private var refreshButton: NSButton!
    private var loadMoreButton: NSButton!
    private var tableView: NSTableView!
    private var statusLabel: NSTextField!
    private var copyStatusButton: NSButton!
    private var spinner: NSProgressIndicator!
    private var emptyLabel: NSTextField!

    private var allGames: [HubcapGame] = []
    private var games: [HubcapGame] = []
    private var totalCount = 0
    private var loadedOffset = 0
    private var isBusy = false
    private var searchTask: Task<Void, Never>?

    init(store: ConfigStore, onConfigChanged: @escaping () -> Void) {
        self.store = store
        self.onConfigChanged = onConfigChanged
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 620))
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Hubcap")
        title.font = Typography.largeTitle
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString:
            "Browse the full Hubcap game library and install Lua manifests directly into macSteam."
        )
        subtitle.font = Typography.body
        subtitle.textColor = Colors.secondaryText
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 0
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let authHeader = settingsGroupLabel("API access")
        let authCopy = NSTextField(labelWithString:
            "Paste a Hubcap API key. macSteam stores it in Keychain and uses Bearer authentication "
            + "for the Hubcap API."
        )
        authCopy.font = Typography.caption
        authCopy.textColor = Colors.secondaryText
        authCopy.lineBreakMode = .byWordWrapping
        authCopy.maximumNumberOfLines = 0
        authCopy.translatesAutoresizingMaskIntoConstraints = false

        apiKeysButton = makeButton(
            title: "Open API Keys",
            target: self,
            action: #selector(openAPIKeys)
        )

        apiKeyField = NSSecureTextField()
        apiKeyField.placeholderString = "smm_… API key"
        apiKeyField.translatesAutoresizingMaskIntoConstraints = false
        apiKeyField.setAccessibilityLabel("Hubcap API key")

        saveKeyButton = makeButton(title: "Save & Verify", target: self, action: #selector(saveKey))
        forgetKeyButton = makeButton(title: "Forget Key", target: self, action: #selector(forgetKey))

        let authButtons = NSStackView(views: [apiKeysButton, saveKeyButton, forgetKeyButton])
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
            apiKeyField.widthAnchor.constraint(equalToConstant: 290),

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
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldSubmitted)

        refreshButton = makeButton(title: "Refresh", target: self, action: #selector(refreshLibrary))
        loadMoreButton = makeButton(title: "Load More", target: self, action: #selector(loadMoreLibrary))

        let searchRow = NSStackView(views: [searchField, refreshButton, loadMoreButton])
        searchRow.orientation = .horizontal
        searchRow.alignment = .centerY
        searchRow.spacing = 8
        searchRow.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = 70
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
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

        statusLabel = NSTextField(wrappingLabelWithString: "Enter your Hubcap API key to load the library.")
        statusLabel.font = Typography.caption
        statusLabel.textColor = Colors.secondaryText
        statusLabel.isSelectable = true
        statusLabel.allowsEditingTextAttributes = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        copyStatusButton = makeButton(title: "Copy", target: self, action: #selector(copyStatus))
        copyStatusButton.controlSize = .small
        copyStatusButton.setAccessibilityLabel("Copy Hubcap status")

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let statusRow = NSStackView(views: [spinner, statusLabel, copyStatusButton])
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
            tableContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        apiKeyField.stringValue = KeychainStore.read(account: keychainAccount) ?? ""
        emptyLabel.isHidden = true
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        let stored = KeychainStore.read(account: keychainAccount) ?? ""
        if apiKeyField.stringValue != stored {
            apiKeyField.stringValue = stored
        }

        guard !stored.isEmpty else {
            setStatus("Enter your Hubcap API key, then choose Save & Verify.", tone: .neutral)
            return
        }

        if allGames.isEmpty {
            loadLibrary(reset: true)
        } else {
            scheduleSearch()
        }
    }

    @objc private func openAPIKeys() {
        NSWorkspace.shared.open(HubcapClient.apiKeysURL)
    }

    @objc private func saveKey() {
        guard !isBusy else { return }

        let key: String
        do {
            key = try validatedKey()
            try KeychainStore.write(key, account: keychainAccount)
        } catch {
            setStatus(error.localizedDescription, tone: .bad)
            return
        }

        apiKeyField.stringValue = key
        allGames.removeAll()
        games.removeAll()
        totalCount = 0
        loadedOffset = 0
        tableView.reloadData()
        emptyLabel.isHidden = true

        loadLibrary(reset: true)

    }

    @objc private func forgetKey() {
        guard !isBusy else { return }

        do {
            try KeychainStore.delete(account: keychainAccount)
            apiKeyField.stringValue = ""
            allGames.removeAll()
            games.removeAll()
            totalCount = 0
            tableView.reloadData()
            loadedOffset = 0
            emptyLabel.isHidden = false
            loadMoreButton.isEnabled = false
            setStatus("Hubcap API key removed.", tone: .neutral)
        } catch {
            setStatus(error.localizedDescription, tone: .bad)
        }
    }

    @objc private func searchFieldSubmitted() {
        scheduleSearch()
    }

    @objc private func refreshLibrary() {
        guard !isBusy else { return }
        searchTask?.cancel()
        loadLibrary(reset: true)
    }

    @objc private func loadMoreLibrary() {
        guard !isBusy, searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        loadLibrary(reset: false)
    }

    func controlTextDidChange(_ obj: Notification) {
        scheduleSearch()
    }

    private func scheduleSearch() {
        searchTask?.cancel()

        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            games = allGames
            tableView.reloadData()
            emptyLabel.stringValue = "No games returned by Hubcap."
            emptyLabel.isHidden = !games.isEmpty
            updateCatalogStatus()
            return
        }

        guard query.count >= 3 else {
            games.removeAll()
            tableView.reloadData()
            emptyLabel.stringValue = "Enter at least 3 characters to search Hubcap."
            emptyLabel.isHidden = false
            setStatus("Enter at least 3 characters to search Hubcap.", tone: .neutral)
            return
        }

        let isAppID = query.allSatisfy({ $0.isNumber })
        guard let key = currentKey() else { return }

        searchTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }

                await MainActor.run {
                    self.setBusy(true, status: "Searching Hubcap…")
                }

                let results = try await self.client.searchGames(
                    query: query,
                    apiKey: key,
                    appID: isAppID
                )
                if Task.isCancelled { return }

                await MainActor.run {
                    self.games = self.deduplicateAndSort(results)
                    self.tableView.reloadData()
                    self.emptyLabel.stringValue = isAppID
                        ? "No game matches App ID \(query)."
                        : "No games match “\(query)”."
                    self.emptyLabel.isHidden = !self.games.isEmpty
                    self.setBusy(false)
                    self.setStatus(
                        "\(self.games.count) result(s) from Hubcap.",
                        tone: self.games.isEmpty ? .neutral : .ok
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    self.setBusy(false)
                    self.setStatus(error.localizedDescription, tone: .bad)
                }
            }
        }
    }

    private func loadLibrary(reset: Bool) {
        guard !isBusy, let key = currentKey() else { return }

        let offset = reset ? 0 : loadedOffset
        setBusy(true, status: reset ? "Loading Hubcap catalog…" : "Loading more Hubcap games…")

        Task {
            do {
                let page = try await client.libraryPage(
                    apiKey: key,
                    limit: 1000,
                    offset: offset
                )

                let merged: [HubcapGame]
                if reset {
                    merged = page.games
                } else {
                    merged = allGames + page.games
                }

                allGames = deduplicateAndSort(merged)
                loadedOffset = offset + page.games.count
                totalCount = page.totalCount
                games = allGames
                tableView.reloadData()
                emptyLabel.stringValue = "No games returned by Hubcap."
                emptyLabel.isHidden = !games.isEmpty
                setBusy(false)
                updateCatalogStatus()
            } catch {
                setBusy(false)
                setStatus(error.localizedDescription, tone: .bad)
            }
        }
    }

    private func updateCatalogStatus() {
        if allGames.isEmpty {
            setStatus("Hubcap returned no games.", tone: .bad)
        } else if loadedOffset < totalCount {
            setStatus(
                "Showing \(allGames.count) of \(totalCount) games. Search uses Hubcap; Load More fetches the next page.",
                tone: .ok
            )
        } else {
            setStatus("Loaded all \(allGames.count) Hubcap games.", tone: .ok)
        }
        loadMoreButton.isEnabled =
            !isBusy &&
            searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            loadedOffset < totalCount
    }


    private func deduplicateAndSort(_ input: [HubcapGame]) -> [HubcapGame] {
        var seen = Set<String>()
        return input
            .filter { seen.insert($0.id).inserted }
            .sorted {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                if order == .orderedSame {
                    return $0.id.localizedStandardCompare($1.id) == .orderedAscending
                }
                return order == .orderedAscending
            }
    }

    private func install(game: HubcapGame) {
        guard !isBusy, let appID = game.appID, let key = currentKey() else { return }

        setBusy(true, status: "Downloading Lua for \(game.name)…")

        Task {
            do {
                let luaText = try await client.downloadLuaText(appID: appID, apiKey: key)

                setStatus("Installing \(game.name)…", tone: .neutral)
                let plan = try await Task.detached(priority: .userInitiated) {
                    try ZipImporter.buildPlan(
                        fromLuaText: luaText,
                        source: URL(fileURLWithPath: "hubcap-\(appID).lua")
                    )
                }.value

                guard plan.mainAppID == appID else {
                    throw HubcapInstallError.appIDMismatch(requested: appID)
                }

                try store.mutate { cfg in
                    _ = ZipImporter.merge(plan, into: &cfg)
                }

                ZipImporter.cleanup(plan.extractDir)
                onConfigChanged()
                setBusy(false)
                setStatus("Installed \(game.name) into macSteam.", tone: .ok)
            } catch {
                setBusy(false)
                setStatus(error.localizedDescription, tone: .bad)
            }
        }
    }

    private func currentKey() -> String? {
        let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            setStatus("Enter your Hubcap API key to load the library.", tone: .neutral)
            return nil
        }

        do {
            _ = try validatedKey()
            return key
        } catch {
            if !isBusy {
                setStatus(error.localizedDescription, tone: .bad)
            }
            return nil
        }
    }

    private func validatedKey() throws -> String {
        let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.range(
            of: #"^smm_[0-9a-f]{96}$"#,
            options: .regularExpression
        ) != nil else {
            throw HubcapClientError.invalidAPIKey
        }
        return key
    }

    @objc private func copyStatus() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(statusLabel.stringValue, forType: .string)
    }

    private func setBusy(_ busy: Bool, status: String? = nil) {
        isBusy = busy
        spinner.isHidden = !busy

        if busy {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }

        apiKeysButton.isEnabled = !busy
        saveKeyButton.isEnabled = !busy
        forgetKeyButton.isEnabled = !busy
        searchField.isEnabled = true
        refreshButton.isEnabled = !busy
        tableView.isEnabled = !busy
        loadMoreButton.isEnabled = !busy && searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && loadedOffset < totalCount

        if let status {
            setStatus(status, tone: .neutral)
        }
    }

    private func setStatus(_ text: String, tone: StatusTone) {
        statusLabel.stringValue = text
        statusLabel.textColor = tone.color
    }
}

extension HubcapViewController: NSSearchFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        scheduleSearch()
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
        70
    }
}

@MainActor
private final class HubcapGameCell: NSTableCellView {
    private static let imageCache = NSCache<NSURL, NSImage>()

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let installButton = NSButton(title: "Install", target: nil, action: nil)

    private var imageTask: Task<Void, Never>?
    private var representedID = ""

    var onInstall: (() -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        wantsLayer = true

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.imageAlignment = .alignCenter
        iconView.image = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: nil)
        iconView.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        iconView.contentTintColor = Colors.quiet
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 6
        iconView.layer?.masksToBounds = true
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = Typography.body
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        metaLabel.font = Typography.caption
        metaLabel.textColor = Colors.secondaryText
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = Typography.caption
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.wantsLayer = true
        statusLabel.layer?.cornerRadius = 6

        installButton.bezelStyle = .rounded
        installButton.controlSize = .small
        installButton.target = self
        installButton.action = #selector(installPressed)
        installButton.translatesAutoresizingMaskIntoConstraints = false
        installButton.setAccessibilityLabel("Install game")

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(metaLabel)
        addSubview(statusLabel)
        addSubview(installButton)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 70),
            iconView.heightAnchor.constraint(equalToConstant: 52),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusLabel.leadingAnchor, constant: -10),

            metaLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            metaLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: installButton.leadingAnchor, constant: -10),

            statusLabel.trailingAnchor.constraint(equalTo: installButton.leadingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),

            installButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            installButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            installButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        imageTask?.cancel()
    }

    func configure(game: HubcapGame) {
        imageTask?.cancel()
        representedID = game.id

        nameLabel.stringValue = game.name
        let type = game.appType?.capitalized ?? "App"
        metaLabel.stringValue = "App ID \(game.id)  •  \(type)"

        installButton.isEnabled = game.appID != nil && game.manifestAvailable

        if game.manifestAvailable {
            statusLabel.stringValue = "Available"
            statusLabel.textColor = .systemGreen
        } else {
            statusLabel.stringValue = "Unavailable"
            statusLabel.textColor = Colors.secondaryText
        }

        iconView.image = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: nil)
        iconView.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        iconView.contentTintColor = Colors.quiet

        guard let url = game.headerImageURL else { return }

        if let cached = Self.imageCache.object(forKey: url as NSURL) {
            iconView.image = cached
            return
        }

        imageTask = Task { [weak self] in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let image = NSImage(data: data), !Task.isCancelled else { return }
                Self.imageCache.setObject(image, forKey: url as NSURL)

                guard let self, self.representedID == game.id else { return }
                self.iconView.image = image
            } catch {
                // The text metadata remains useful if the Steam image is unavailable.
            }
        }
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
