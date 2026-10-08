import AppKit

@MainActor
final class HubcapViewController: NSViewController {
    let store: ConfigStore
    let onConfigChanged: () -> Void

    // Keep all Hubcap API behavior in HubcapClient. This view only orchestrates UI state.
    private let client = HubcapClient()
    private let keychainAccount = "hubcap-api-key"

    private var apiKeyField: NSSecureTextField!
    private var saveKeyButton: NSButton!
    private var forgetKeyButton: NSButton!
    private var apiKeysButton: NSButton!
    private var apiStatusLabel: NSTextField!

    private var searchField: NSSearchField!
    private var scopeControl: NSSegmentedControl!
    private var refreshButton: NSButton!
    private var loadMoreButton: NSButton!
    private var tableView: NSTableView!
    private var resultCountLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var copyStatusButton: NSButton!
    private var spinner: NSProgressIndicator!
    private var emptyState: EmptyStateView!
    private var installedCountLabel: NSTextField!

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
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 680))
        root.translatesAutoresizingMaskIntoConstraints = false

        // MARK: Header

        let heroIcon = NSImageView()
        heroIcon.image = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: nil)
        heroIcon.symbolConfiguration = .init(pointSize: 26, weight: .semibold)
        heroIcon.contentTintColor = .controlAccentColor
        heroIcon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Find games in Hubcap")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString:
            "Search the Hubcap library, then install a Lua manifest directly into macSteam."
        )
        subtitle.font = Typography.body
        subtitle.textColor = Colors.secondaryText
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 2
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let heroText = NSStackView(views: [title, subtitle])
        heroText.orientation = .vertical
        heroText.alignment = .leading
        heroText.spacing = 3
        heroText.translatesAutoresizingMaskIntoConstraints = false

        let hero = NSStackView(views: [heroIcon, heroText])
        hero.orientation = .horizontal
        hero.alignment = .top
        hero.spacing = 12
        hero.translatesAutoresizingMaskIntoConstraints = false

        installedCountLabel = makeMetricLabel("0 installed")
        let catalogCount = makeMetricLabel("Hubcap catalog")
        let stats = NSStackView(views: [installedCountLabel, catalogCount])
        stats.orientation = .horizontal
        stats.alignment = .centerY
        stats.spacing = 8
        stats.translatesAutoresizingMaskIntoConstraints = false

        let heroRow = NSStackView(views: [hero, stats])
        heroRow.orientation = .horizontal
        heroRow.alignment = .top
        heroRow.spacing = 12
        heroRow.translatesAutoresizingMaskIntoConstraints = false
        hero.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hero.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // MARK: API access

        let apiHeader = settingsGroupLabel("Connection")

        apiStatusLabel = NSTextField(labelWithString: "")
        apiStatusLabel.font = Typography.caption
        apiStatusLabel.textColor = Colors.secondaryText
        apiStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        apiStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        apiKeysButton = makeButton(
            title: "Get API Key",
            target: self,
            action: #selector(openAPIKeys)
        )
        apiKeysButton.controlSize = .small

        apiKeyField = NSSecureTextField()
        apiKeyField.placeholderString = "Paste your smm_ API key"
        apiKeyField.translatesAutoresizingMaskIntoConstraints = false
        apiKeyField.setAccessibilityLabel("Hubcap API key")
        apiKeyField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        apiKeyField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        saveKeyButton = makeButton(title: "Save", target: self, action: #selector(saveKey))
        saveKeyButton.controlSize = .small

        forgetKeyButton = makeButton(title: "Forget", target: self, action: #selector(forgetKey))
        forgetKeyButton.controlSize = .small

        let keyButtons = NSStackView(views: [apiKeysButton, saveKeyButton, forgetKeyButton])
        keyButtons.orientation = .horizontal
        keyButtons.alignment = .centerY
        keyButtons.spacing = 6
        keyButtons.translatesAutoresizingMaskIntoConstraints = false

        let apiTop = NSStackView(views: [apiStatusLabel, apiKeysButton])
        apiTop.orientation = .horizontal
        apiTop.alignment = .centerY
        apiTop.spacing = 8
        apiTop.translatesAutoresizingMaskIntoConstraints = false
        apiStatusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let apiBottom = NSStackView(views: [apiKeyField, keyButtons])
        apiBottom.orientation = .horizontal
        apiBottom.alignment = .centerY
        apiBottom.spacing = 8
        apiBottom.translatesAutoresizingMaskIntoConstraints = false

        let apiCard = makeCard()
        apiCard.addSubview(apiTop)
        apiCard.addSubview(apiBottom)

        NSLayoutConstraint.activate([
            apiTop.topAnchor.constraint(equalTo: apiCard.topAnchor, constant: 12),
            apiTop.leadingAnchor.constraint(equalTo: apiCard.leadingAnchor, constant: 14),
            apiTop.trailingAnchor.constraint(equalTo: apiCard.trailingAnchor, constant: -14),

            apiBottom.topAnchor.constraint(equalTo: apiTop.bottomAnchor, constant: 8),
            apiBottom.leadingAnchor.constraint(equalTo: apiCard.leadingAnchor, constant: 14),
            apiBottom.trailingAnchor.constraint(equalTo: apiCard.trailingAnchor, constant: -14),
            apiBottom.bottomAnchor.constraint(equalTo: apiCard.bottomAnchor, constant: -12),

            apiKeyField.heightAnchor.constraint(equalToConstant: 28),
        ])

        // MARK: Search

        let searchHeader = settingsGroupLabel("Library")

        searchField = NSSearchField()
        searchField.placeholderString = "Search game title or App ID"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityLabel("Search Hubcap games")
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldSubmitted)
        searchField.controlSize = .large
        searchField.font = .systemFont(ofSize: 15)

        scopeControl = NSSegmentedControl(
            labels: ["All", "Installed"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(scopeChanged)
        )
        scopeControl.selectedSegment = 0
        scopeControl.controlSize = .large
        scopeControl.setAccessibilityLabel("Hubcap game filter")

        refreshButton = NSButton(
            image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")!,
            target: self,
            action: #selector(refreshLibrary)
        )
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .large
        refreshButton.toolTip = "Refresh the Hubcap library"
        refreshButton.setAccessibilityLabel("Refresh Hubcap library")
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        let searchBar = NSStackView(views: [searchField, scopeControl, refreshButton])
        searchBar.orientation = .horizontal
        searchBar.alignment = .centerY
        searchBar.spacing = 8
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        resultCountLabel = NSTextField(labelWithString: "Ready to search")
        resultCountLabel.font = Typography.caption
        resultCountLabel.textColor = Colors.secondaryText
        resultCountLabel.translatesAutoresizingMaskIntoConstraints = false

        let sortLabel = NSTextField(labelWithString: "A–Z")
        sortLabel.font = Typography.caption
        sortLabel.textColor = Colors.quiet
        sortLabel.translatesAutoresizingMaskIntoConstraints = false

        let resultsHeader = NSStackView(views: [resultCountLabel, sortLabel])
        resultsHeader.orientation = .horizontal
        resultsHeader.alignment = .centerY
        resultsHeader.spacing = 8
        resultsHeader.translatesAutoresizingMaskIntoConstraints = false
        resultCountLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // MARK: Results list

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = 82
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .regular
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self

        let gameColumn = NSTableColumn(identifier: .init("game"))
        gameColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(gameColumn)

        let scroll = makeScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = tableView

        emptyState = EmptyStateView(
            symbol: "magnifyingglass",
            prompt: "No games to show",
            hint: "Search for a title or switch back to All."
        )
        emptyState.isHidden = true

        let listCard = makeCard()
        listCard.addSubview(scroll)
        listCard.addSubview(emptyState)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: listCard.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: listCard.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: listCard.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: listCard.bottomAnchor),

            emptyState.centerXAnchor.constraint(equalTo: listCard.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: listCard.centerYAnchor),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: listCard.leadingAnchor, constant: 20),
            emptyState.trailingAnchor.constraint(lessThanOrEqualTo: listCard.trailingAnchor, constant: -20),
        ])

        // MARK: Footer

        loadMoreButton = makeButton(title: "Load More", target: self, action: #selector(loadMoreLibrary))
        loadMoreButton.controlSize = .small

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(wrappingLabelWithString: "Enter your Hubcap API key to load the library.")
        statusLabel.font = Typography.caption
        statusLabel.textColor = Colors.secondaryText
        statusLabel.isSelectable = true
        statusLabel.allowsEditingTextAttributes = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        copyStatusButton = makeButton(title: "Copy", target: self, action: #selector(copyStatus))
        copyStatusButton.controlSize = .small

        let footerLeft = NSStackView(views: [spinner, statusLabel, copyStatusButton])
        footerLeft.orientation = .horizontal
        footerLeft.alignment = .centerY
        footerLeft.spacing = 7
        footerLeft.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [footerLeft, loadMoreButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12
        footer.translatesAutoresizingMaskIntoConstraints = false
        footerLeft.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // MARK: Root

        let stack = NSStackView(views: [
            heroRow,
            apiHeader, apiCard,
            searchHeader, searchBar,
            resultsHeader, listCard,
            footer,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(12, after: heroRow)
        stack.setCustomSpacing(5, after: apiHeader)
        stack.setCustomSpacing(16, after: apiCard)
        stack.setCustomSpacing(5, after: searchHeader)
        stack.setCustomSpacing(9, after: searchBar)
        stack.setCustomSpacing(7, after: resultsHeader)
        stack.setCustomSpacing(8, after: listCard)

        root.addSubview(stack)

        let m = Metrics.paneMargin
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: m),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -m),

            heroRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            apiCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            searchBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resultsHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            listCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            listCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),

            scopeControl.widthAnchor.constraint(equalToConstant: 140),
            refreshButton.widthAnchor.constraint(equalToConstant: 34),
            refreshButton.heightAnchor.constraint(equalToConstant: 34),
        ])

        apiKeyField.stringValue = KeychainStore.read(account: keychainAccount) ?? ""
        updateInstalledMetric()
        updateAPIStatus()
        updateEmptyState()
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        let stored = KeychainStore.read(account: keychainAccount) ?? ""
        if apiKeyField.stringValue != stored {
            apiKeyField.stringValue = stored
        }

        updateInstalledMetric()
        updateAPIStatus()

        guard !stored.isEmpty else {
            setStatus("Connect Hubcap with an API key to start browsing.", tone: .neutral)
            return
        }

        if allGames.isEmpty {
            loadLibrary(reset: true)
        } else {
            applyScopeAndReload()
            scheduleSearch()
        }
    }

    // MARK: API actions

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
        updateInstalledMetric()
        updateAPIStatus()
        updateEmptyState()
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
            loadedOffset = 0
            tableView.reloadData()
            updateInstalledMetric()
            updateAPIStatus()
            updateEmptyState()
            loadMoreButton.isEnabled = false
            resultCountLabel.stringValue = "Ready to search"
            setStatus("Hubcap API key removed.", tone: .neutral)
        } catch {
            setStatus(error.localizedDescription, tone: .bad)
        }
    }

    // MARK: Search / filtering

    @objc private func searchFieldSubmitted() {
        scheduleSearch()
    }

    @objc private func scopeChanged() {
        searchTask?.cancel()
        applyScopeAndReload()

        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            scheduleSearch()
        } else {
            updateCatalogStatus()
        }
    }

    @objc private func refreshLibrary() {
        guard !isBusy else { return }
        searchTask?.cancel()
        loadLibrary(reset: true)
    }

    @objc private func loadMoreLibrary() {
        guard !isBusy else { return }
        guard searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        guard scopeControl.selectedSegment == 0 else { return }
        loadLibrary(reset: false)
    }

    func controlTextDidChange(_ obj: Notification) {
        scheduleSearch()
    }

    private func scheduleSearch() {
        searchTask?.cancel()

        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if query.isEmpty {
            applyScopeAndReload()
            updateCatalogStatus()
            return
        }

        guard query.count >= 3 else {
            games.removeAll()
            tableView.reloadData()
            resultCountLabel.stringValue = "Keep typing…"
            emptyState.configure(
                symbol: "text.magnifyingglass",
                prompt: "Search needs 3 characters",
                hint: "Enter a game title or App ID."
            )
            emptyState.isHidden = false
            setStatus("Enter at least 3 characters to search Hubcap.", tone: .neutral)
            return
        }

        guard let key = currentKey() else { return }

        let isAppID = query.allSatisfy({ $0.isNumber })

        searchTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }

                setBusy(true, status: "Searching Hubcap…")

                let results = try await client.searchGames(
                    query: query,
                    apiKey: key,
                    appID: isAppID
                )
                if Task.isCancelled { return }

                let scoped = scopeControl.selectedSegment == 1
                    ? results.filter { isInstalled($0) }
                    : results

                games = deduplicateAndSort(scoped)
                tableView.reloadData()
                resultCountLabel.stringValue = resultSummary(count: games.count, search: query)
                emptyState.configure(
                    symbol: scopeControl.selectedSegment == 1 ? "checkmark.circle" : "magnifyingglass",
                    prompt: scopeControl.selectedSegment == 1
                        ? "No installed matches"
                        : "No games found",
                    hint: scopeControl.selectedSegment == 1
                        ? "Try All or install a game from the library."
                        : "Try a different title or App ID."
                )
                emptyState.isHidden = !games.isEmpty
                setBusy(false)
                setStatus(
                    games.isEmpty ? "No Hubcap games matched that search." : "(games.count) result(s) from Hubcap.",
                    tone: games.isEmpty ? .neutral : .ok
                )
            } catch is CancellationError {
                return
            } catch {
                setBusy(false)
                setStatus(error.localizedDescription, tone: .bad)
            }
        }
    }

    private func applyScopeAndReload() {
        if scopeControl.selectedSegment == 1 {
            games = allGames.filter { isInstalled($0) }
        } else {
            games = allGames
        }

        games = deduplicateAndSort(games)
        tableView.reloadData()
        resultCountLabel.stringValue = games.isEmpty ? "No games" : "(games.count) shown"
        emptyState.configure(
            symbol: scopeControl.selectedSegment == 1 ? "checkmark.circle" : "magnifyingglass",
            prompt: scopeControl.selectedSegment == 1 ? "No installed games here" : "No games returned",
            hint: scopeControl.selectedSegment == 1
                ? "Installed games will appear here."
                : "Try a different search."
        )
        updateEmptyState()
        loadMoreButton.isEnabled =
            !isBusy &&
            scopeControl.selectedSegment == 0 &&
            searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            loadedOffset < totalCount
    }

    private func loadLibrary(reset: Bool) {
        guard !isBusy, let key = currentKey() else { return }

        let offset = reset ? 0 : loadedOffset
        setBusy(true, status: reset ? "Loading Hubcap library…" : "Loading more games…")

        Task {
            do {
                // API endpoint, pagination size, and request semantics are unchanged.
                let page = try await client.libraryPage(
                    apiKey: key,
                    limit: 1000,
                    offset: offset
                )

                let merged: [HubcapGame] = reset ? page.games : (allGames + page.games)
                allGames = deduplicateAndSort(merged)
                loadedOffset = offset + page.games.count
                totalCount = page.totalCount

                updateInstalledMetric()
                applyScopeAndReload()
                updateCatalogStatus()
                setBusy(false)
            } catch {
                setBusy(false)
                setStatus(error.localizedDescription, tone: .bad)
            }
        }
    }

    private func updateCatalogStatus() {
        if allGames.isEmpty {
            setStatus("Hubcap returned no games.", tone: .neutral)
            resultCountLabel.stringValue = "No games"
        } else if loadedOffset < totalCount {
            setStatus(
                "Showing (allGames.count) of (totalCount). Search Hubcap or browse the loaded library.",
                tone: .ok
            )
            resultCountLabel.stringValue = resultCountLabelForScope()
        } else {
            setStatus("Loaded all (allGames.count) Hubcap games.", tone: .ok)
            resultCountLabel.stringValue = resultCountLabelForScope()
        }

        loadMoreButton.isEnabled =
            !isBusy &&
            scopeControl.selectedSegment == 0 &&
            searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            loadedOffset < totalCount
    }

    // MARK: Install

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
        guard !isInstalled(game) else {
            refreshInstalledState()
            return
        }

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
                refreshInstalledState()
                onConfigChanged()
                setBusy(false)
                setStatus("Installed \(game.name) into macSteam.", tone: .ok)
            } catch {
                setBusy(false)
                setStatus(error.localizedDescription, tone: .bad)
            }
        }
    }

    // MARK: Helpers

    private func currentKey() -> String? {
        let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            setStatus("Enter your Hubcap API key to browse the library.", tone: .neutral)
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

    private func isInstalled(_ game: HubcapGame) -> Bool {
        guard let appID = game.appID else { return false }
        return store.config.apps.contains(appID)
    }

    private func refreshInstalledState() {
        updateInstalledMetric()
        applyScopeAndReload()
    }

    private func updateInstalledMetric() {
        let installed = Set(store.config.apps).count
        installedCountLabel?.stringValue = "\(installed) installed"
    }

    private func updateAPIStatus() {
        let hasKey = !(apiKeyField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        apiStatusLabel?.stringValue = hasKey
            ? "●  Connected — key stored securely in Keychain"
            : "○  Not connected — add your Hubcap API key to browse"
        apiStatusLabel?.textColor = hasKey ? .systemGreen : Colors.secondaryText
        apiKeysButton?.title = hasKey ? "API Keys" : "Get API Key"
    }

    private func resultSummary(count: Int, search: String) -> String {
        guard search.isEmpty == false else { return "\(count) shown" }
        return "\(count) result(s)"
    }

    private func resultCountLabelForScope() -> String {
        let installedOnly = scopeControl.selectedSegment == 1
        if installedOnly {
            let installedVisible = games.count
            return "\(installedVisible) installed"
        }
        return games.isEmpty ? "No games" : "\(games.count) shown"
    }

    private func updateEmptyState() {
        emptyState.isHidden = !games.isEmpty
    }

    private func makeMetricLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = Typography.caption
        field.textColor = Colors.secondaryText
        field.alignment = .right
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func makeCard() -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.applyCardSurface()
        return card
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
        scopeControl.isEnabled = !busy
        refreshButton.isEnabled = !busy
        tableView.isEnabled = !busy

        loadMoreButton.isEnabled =
            !busy &&
            scopeControl.selectedSegment == 0 &&
            searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            loadedOffset < totalCount

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
        cell.onResolveName = { [client] appID in
            await client.steamAppName(appID: appID)
        }
        cell.isInstalled = isInstalled(game)
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
        82
    }
}

@MainActor
private final class HubcapGameCell: NSTableCellView {
    private static let imageCache = NSCache<NSURL, NSImage>()

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let availabilityLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "Install", target: nil, action: nil)
    private let installedIcon = NSImageView()
    private let installedLabel = NSTextField(labelWithString: "Installed")

    private var imageTask: Task<Void, Never>?
    private var nameTask: Task<Void, Never>?
    private var representedID = ""

    var onInstall: (() -> Void)?
    var onResolveName: ((Int) async -> String?)?
    var isInstalled = false

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
        iconView.layer?.cornerRadius = 7
        iconView.layer?.masksToBounds = true
        iconView.layer?.backgroundColor = Colors.quiet.withAlphaComponent(0.08).cgColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        metaLabel.font = Typography.caption
        metaLabel.textColor = Colors.secondaryText
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        availabilityLabel.font = Typography.caption
        availabilityLabel.alignment = .right
        availabilityLabel.translatesAutoresizingMaskIntoConstraints = false

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .regular
        actionButton.target = self
        actionButton.action = #selector(installPressed)
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.setAccessibilityLabel("Install game")

        installedIcon.image = NSImage(
            systemSymbolName: "checkmark.circle.fill",
            accessibilityDescription: "Installed"
        )
        installedIcon.symbolConfiguration = .init(pointSize: 18, weight: .semibold)
        installedIcon.contentTintColor = .systemGreen
        installedIcon.translatesAutoresizingMaskIntoConstraints = false
        installedIcon.setAccessibilityElement(false)

        installedLabel.font = .systemFont(ofSize: 12, weight: .medium)
        installedLabel.textColor = .systemGreen
        installedLabel.translatesAutoresizingMaskIntoConstraints = false
        installedLabel.setAccessibilityElement(false)

        let installedStack = NSStackView(views: [installedIcon, installedLabel])
        installedStack.orientation = .horizontal
        installedStack.alignment = .centerY
        installedStack.spacing = 5
        installedStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(metaLabel)
        addSubview(availabilityLabel)
        addSubview(actionButton)
        addSubview(installedStack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 96),
            iconView.heightAnchor.constraint(equalToConstant: 56),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 14),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 15),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: availabilityLabel.leadingAnchor, constant: -12),

            metaLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            metaLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -12),

            availabilityLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            availabilityLabel.topAnchor.constraint(equalTo: topAnchor, constant: 16),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            actionButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            actionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),

            installedStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            installedStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        installedStack.setContentHuggingPriority(.required, for: .horizontal)
        installedStack.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        imageTask?.cancel()
        nameTask?.cancel()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageTask?.cancel()
        nameTask?.cancel()
        representedID = ""
        isInstalled = false
        actionButton.isHidden = false
        installedIcon.isHidden = true
        installedLabel.isHidden = true
    }

    func configure(game: HubcapGame) {
        imageTask?.cancel()
        nameTask?.cancel()
        representedID = game.id

        nameLabel.stringValue = game.name
        let type = game.appType?.capitalized ?? "App"
        metaLabel.stringValue = "App ID \(game.id)  •  \(type)"

        if game.name == "App \(game.id)", let appID = game.appID {
            let expectedID = game.id
            let resolver = onResolveName
            nameLabel.stringValue = "Loading game name…"

            nameTask = Task { [weak self] in
                guard let resolver else { return }
                let resolved = await resolver(appID)
                guard let self, self.representedID == expectedID, !Task.isCancelled else { return }
                self.nameLabel.stringValue = resolved ?? game.name
            }
        }

        availabilityLabel.stringValue = game.manifestAvailable ? "Manifest available" : "No manifest"
        availabilityLabel.textColor = game.manifestAvailable ? Colors.secondaryText : Colors.quiet

        if isInstalled {
            actionButton.isHidden = true
            installedIcon.isHidden = false
            installedLabel.isHidden = false
        } else {
            actionButton.isHidden = false
            installedIcon.isHidden = true
            installedLabel.isHidden = true
            actionButton.isEnabled = game.appID != nil && game.manifestAvailable
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
                // Keep the built-in icon if Steam art is unavailable.
            }
        }
    }

    @objc private func installPressed() {
        onInstall?()
    }
}

private extension EmptyStateView {
    func configure(symbol: String, prompt: String, hint: String) {
        // Rebuild only the text/glyph state of the lightweight empty state view.
        subviews.forEach { $0.removeFromSuperview() }

        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        glyph.symbolConfiguration = .init(pointSize: 34, weight: .regular)
        glyph.contentTintColor = Colors.quiet
        glyph.setAccessibilityElement(false)

        let promptLabel = NSTextField(labelWithString: prompt)
        promptLabel.font = Typography.body
        promptLabel.textColor = Colors.secondaryText
        promptLabel.alignment = .center

        let hintLabel = NSTextField(labelWithString: hint)
        hintLabel.font = Typography.caption
        hintLabel.textColor = Colors.quiet
        hintLabel.alignment = .center

        orientation = .vertical
        alignment = .centerX
        spacing = 4
        setViews([glyph, promptLabel, hintLabel], in: .center)
        setCustomSpacing(8, after: glyph)
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
