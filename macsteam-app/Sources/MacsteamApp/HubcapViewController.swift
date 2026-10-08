import AppKit

@MainActor
final class HubcapViewController: NSViewController {
    let store: ConfigStore
    let onConfigChanged: () -> Void

    // Keep all Hubcap API behavior in HubcapClient. This view only orchestrates UI state.
    private let client = HubcapClient()
    private let libraryCache = HubcapLibraryCache()
    private var cacheRefreshTask: Task<Void, Never>?
    private var apiStatusIcon: NSImageView!
    private var apiStatusTitle: NSTextField!
    private var apiStatusDetail: NSTextField!
    private var apiSettingsButton: NSButton!

    private var searchField: NSSearchField!
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
    private var isUpdatingCache = false
    private var didStartCacheRefresh = false

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


        // MARK: Hubcap connection

        let apiHeader = settingsGroupLabel("Connect to Hubcap")

        apiStatusIcon = NSImageView()
        apiStatusIcon.translatesAutoresizingMaskIntoConstraints = false
        apiStatusIcon.setAccessibilityElement(false)

        apiStatusTitle = NSTextField(labelWithString: "Not connected")
        apiStatusTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        apiStatusTitle.textColor = .labelColor
        apiStatusTitle.translatesAutoresizingMaskIntoConstraints = false

        apiStatusDetail = NSTextField(labelWithString: "Add an access key in Settings.")
        apiStatusDetail.font = Typography.caption
        apiStatusDetail.textColor = Colors.secondaryText
        apiStatusDetail.translatesAutoresizingMaskIntoConstraints = false
        apiStatusDetail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let apiText = NSStackView(views: [apiStatusTitle, apiStatusDetail])
        apiText.orientation = .vertical
        apiText.alignment = .leading
        apiText.spacing = 2
        apiText.translatesAutoresizingMaskIntoConstraints = false
        apiText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        apiSettingsButton = makeButton(
            title: "Settings",
            target: self,
            action: #selector(openHubcapSettings)
        )

        let apiCard = makeCard()
        apiCard.addSubview(apiStatusIcon)
        apiCard.addSubview(apiText)
        apiCard.addSubview(apiSettingsButton)

        NSLayoutConstraint.activate([
            apiStatusIcon.leadingAnchor.constraint(equalTo: apiCard.leadingAnchor, constant: 14),
            apiStatusIcon.centerYAnchor.constraint(equalTo: apiCard.centerYAnchor),
            apiStatusIcon.widthAnchor.constraint(equalToConstant: 12),
            apiStatusIcon.heightAnchor.constraint(equalToConstant: 12),

            apiText.leadingAnchor.constraint(equalTo: apiStatusIcon.trailingAnchor, constant: 10),
            apiText.topAnchor.constraint(equalTo: apiCard.topAnchor, constant: 11),
            apiText.bottomAnchor.constraint(equalTo: apiCard.bottomAnchor, constant: -11),
            apiText.trailingAnchor.constraint(lessThanOrEqualTo: apiSettingsButton.leadingAnchor, constant: -12),

            apiSettingsButton.trailingAnchor.constraint(equalTo: apiCard.trailingAnchor, constant: -14),
            apiSettingsButton.centerYAnchor.constraint(equalTo: apiCard.centerYAnchor),
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

        let searchBar = NSStackView(views: [searchField, refreshButton])
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

            refreshButton.widthAnchor.constraint(equalToConstant: 34),
            refreshButton.heightAnchor.constraint(equalToConstant: 34),
        ])

        updateInstalledMetric()
        updateAPIStatus()
        updateEmptyState()
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        updateInstalledMetric()
        updateAPIStatus()

        loadCachedLibraryThenStart()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        // The full database refresh is intentionally allowed to continue while the Hubcap
        // controller remains owned by MainViewController. It is cancelled only if the
        // controller itself is released.
    }

    deinit {
        cacheRefreshTask?.cancel()
        searchTask?.cancel()
    }

    // MARK: Hubcap settings

    @objc private func openHubcapSettings() {
        let alert = NSAlert()
        alert.messageText = "Hubcap Settings"
        alert.informativeText = "Enter your Hubcap access key once. macSteam will remember it for future launches."

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 108))

        let keyLabel = NSTextField(labelWithString: "Access key")
        keyLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        keyLabel.translatesAutoresizingMaskIntoConstraints = false

        let keyField = NSSecureTextField()
        keyField.placeholderString = "Paste your Hubcap access key"
        keyField.stringValue = HubcapCredentialStore.apiKey ?? ""
        keyField.translatesAutoresizingMaskIntoConstraints = false
        keyField.setAccessibilityLabel("Hubcap access key")

        let urlLabel = NSTextField(labelWithString: "https://hubcapmanifest.com/api-keys/")
        urlLabel.font = Typography.caption
        urlLabel.textColor = Colors.secondaryText
        urlLabel.translatesAutoresizingMaskIntoConstraints = false
        urlLabel.lineBreakMode = .byTruncatingTail

        let openURLButton = NSButton(
            title: "Open API key page",
            target: self,
            action: #selector(openAPIKeys)
        )
        openURLButton.bezelStyle = .rounded
        openURLButton.controlSize = .small
        openURLButton.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(keyLabel)
        container.addSubview(keyField)
        container.addSubview(urlLabel)
        container.addSubview(openURLButton)

        NSLayoutConstraint.activate([
            keyLabel.topAnchor.constraint(equalTo: container.topAnchor),
            keyLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),

            keyField.topAnchor.constraint(equalTo: keyLabel.bottomAnchor, constant: 7),
            keyField.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            keyField.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            keyField.heightAnchor.constraint(equalToConstant: 28),

            urlLabel.topAnchor.constraint(equalTo: keyField.bottomAnchor, constant: 8),
            urlLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            urlLabel.trailingAnchor.constraint(lessThanOrEqualTo: openURLButton.leadingAnchor, constant: -10),

            openURLButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            openURLButton.centerYAnchor.constraint(equalTo: urlLabel.centerYAnchor),
        ])

        alert.accessoryView = container
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Disconnect")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            do {
                let key = try validateHubcapKey(keyField.stringValue)
                HubcapCredentialStore.save(key)
                didStartCacheRefresh = false
                updateAPIStatus()
                allGames.removeAll()
                games.removeAll()
                totalCount = 0
                loadedOffset = 0
                tableView.reloadData()
                updateEmptyState()
                loadLibrary(reset: true)
            } catch {
                setStatus(error.localizedDescription, tone: .bad)
            }

        case .alertSecondButtonReturn:
            HubcapCredentialStore.remove()
            updateAPIStatus()
            allGames.removeAll()
            games.removeAll()
            totalCount = 0
            loadedOffset = 0
            tableView.reloadData()
            updateEmptyState()
            loadMoreButton.isEnabled = false
            resultCountLabel.stringValue = "Ready to connect"
            setStatus("Hubcap disconnected.", tone: .neutral)

        default:
            break
        }
    }

    @objc private func openAPIKeys() {
        NSWorkspace.shared.open(HubcapClient.apiKeysURL)
    }

    private func validateHubcapKey(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.range(
            of: #"^smm_[0-9a-f]{96}$"#,
            options: .regularExpression
        ) != nil else {
            throw HubcapClientError.invalidAPIKey
        }
        return key
    }

    // MARK: Search / filtering

    @objc private func searchFieldSubmitted() {
        scheduleSearch()
    }

    @objc private func refreshLibrary() {
        guard !isBusy else { return }
        searchTask?.cancel()

        if HubcapCredentialStore.apiKey != nil {
            startBackgroundDatabaseRefresh(force: true)
        } else {
            loadLibrary(reset: true)
        }
    }

    @objc private func loadMoreLibrary() {
        guard !isBusy else { return }
        guard searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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

        if query.isEmpty {
            games = allGames
            tableView.reloadData()
            resultCountLabel.stringValue = allGames.isEmpty ? "No games" : "\(allGames.count) shown"
            emptyState.configure(
                symbol: "books.vertical",
                prompt: "Browse the Hubcap library",
                hint: "Search for a game or App ID."
            )
            updateEmptyState()
            updateCatalogStatus()
            return
        }

        guard query.count >= 2 else {
            games.removeAll()
            tableView.reloadData()
            resultCountLabel.stringValue = "Keep typing…"
            emptyState.configure(
                symbol: "text.magnifyingglass",
                prompt: "Search needs 2 characters",
                hint: "Search by game title or App ID."
            )
            emptyState.isHidden = false
            return
        }

        let normalized = query.localizedLowercase
        let isAppID = query.allSatisfy { $0.isNumber }

        games = allGames.filter { game in
            if isAppID {
                return game.id == query
            }
            return game.name.localizedLowercase.contains(normalized)
                || game.id.contains(query)
        }
        games = deduplicateAndSort(games)

        resultCountLabel.stringValue = games.isEmpty
            ? "No matches"
            : "\(games.count) result\(games.count == 1 ? "" : "s")"

        emptyState.configure(
            symbol: "magnifyingglass",
            prompt: "No games found",
            hint: "Try another title or App ID."
        )
        emptyState.isHidden = !games.isEmpty
        setStatus(
            games.isEmpty ? "No games matched your search." : "\(games.count) local result(s).",
            tone: games.isEmpty ? .neutral : .ok
        )
        tableView.reloadData()
    }

    private func loadCachedLibraryThenStart() {
        Task { [weak self] in
            guard let self else { return }

            let snapshot = await libraryCache.load()

            if let snapshot {
                games = deduplicateAndSort(snapshot.games)
                allGames = games
                totalCount = snapshot.totalCount
                loadedOffset = games.count
                tableView.reloadData()
                resultCountLabel.stringValue = "\(games.count) cached games"
                emptyState.configure(
                    symbol: "books.vertical",
                    prompt: "Hubcap library",
                    hint: "Search the local database while Hubcap updates in the background."
                )
                updateEmptyState()
                setStatus(
                    "Loaded \(games.count) games from the local database. Updating in background…",
                    tone: .ok
                )
                scheduleSearch()
            }

            if snapshot == nil && allGames.isEmpty {
                loadLibrary(reset: true)
            }

            startBackgroundDatabaseRefresh()
        }
    }

    func startBackgroundDatabaseRefresh(force: Bool = false) {
        guard HubcapCredentialStore.apiKey != nil else { return }
        if !force && didStartCacheRefresh { return }
        didStartCacheRefresh = true
        refreshLibraryDatabaseInBackground()
    }

    private func refreshLibraryDatabaseInBackground() {
        guard !isUpdatingCache, let key = HubcapCredentialStore.apiKey else { return }

        isUpdatingCache = true

        cacheRefreshTask?.cancel()
        cacheRefreshTask = Task.detached(priority: .utility) { [client, libraryCache] in
            do {
                var offset = 0
                var totalCount = 0
                var collected: [HubcapGame] = []
                var lastStatusUpdate = Date.distantPast

                while !Task.isCancelled {
                    let page = try await client.libraryPage(
                        apiKey: key,
                        limit: 1000,
                        offset: offset
                    )

                    if offset == 0 {
                        totalCount = page.totalCount
                    }

                    collected.append(contentsOf: page.games)
                    offset += page.games.count

                    if page.games.isEmpty || offset >= page.totalCount {
                        break
                    }

                    if Date().timeIntervalSince(lastStatusUpdate) >= 2 {
                        lastStatusUpdate = Date()
                        let progress = page.totalCount == 0
                            ? 0
                            : Int((Double(offset) / Double(page.totalCount)) * 100)

                        await MainActor.run { [weak self] in
                            guard let self, !self.isBusy else { return }
                            self.setStatus(
                                "Updating Hubcap database… \(progress)%",
                                tone: .neutral
                            )
                        }
                    }
                }

                let snapshot = HubcapLibrarySnapshot(
                    updatedAt: Date(),
                    totalCount: totalCount,
                    games: collected
                )
                try await libraryCache.save(snapshot)

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isUpdatingCache = false
                    guard self.isViewLoaded else { return }
                    self.allGames = self.deduplicateAndSort(collected)
                    self.totalCount = totalCount
                    self.loadedOffset = collected.count
                    self.games = self.allGames
                    self.tableView.reloadData()
                    self.resultCountLabel.stringValue = "\(self.allGames.count) games"
                    self.emptyState.configure(
                        symbol: "books.vertical",
                        prompt: "Hubcap library",
                        hint: "Search the local database."
                    )
                    self.updateEmptyState()
                    self.setStatus(
                        "Hubcap database updated — \(self.allGames.count) games available offline.",
                        tone: .ok
                    )
                    self.scheduleSearch()
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    self?.isUpdatingCache = false
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isUpdatingCache = false
                    guard self.isViewLoaded, !self.isBusy else { return }
                    self.setStatus(
                        "Using the saved Hubcap database. Background update failed: \(error.localizedDescription)",
                        tone: .warn
                    )
                }
            }
        }
    }

    private func applyLibraryRows() {
        games = deduplicateAndSort(allGames)
        tableView.reloadData()
        resultCountLabel.stringValue = games.isEmpty ? "No games" : "\(games.count) shown"
        emptyState.configure(
            symbol: "books.vertical",
            prompt: "Browse the Hubcap library",
            hint: "Search for a game or scroll through the catalog."
        )
        updateEmptyState()
        loadMoreButton.isEnabled =
            !isBusy &&
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
                    limit: 100,
                    offset: offset
                )

                let merged: [HubcapGame] = reset ? page.games : (allGames + page.games)
                allGames = deduplicateAndSort(merged)
                loadedOffset = offset + page.games.count
                totalCount = page.totalCount

                updateInstalledMetric()
                applyLibraryRows()
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
            resultCountLabel.stringValue = "\(games.count) shown"
        } else {
            setStatus("Loaded all (allGames.count) Hubcap games.", tone: .ok)
            resultCountLabel.stringValue = "\(games.count) shown"
        }

        loadMoreButton.isEnabled =
            !isBusy &&
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
        guard let key = HubcapCredentialStore.apiKey else {
            setStatus("Open Hubcap Settings to add your access key.", tone: .neutral)
            return nil
        }

        do {
            return try validateHubcapKey(key)
        } catch {
            if !isBusy {
                setStatus(error.localizedDescription, tone: .bad)
            }
            return nil
        }
    }

    private func isInstalled(_ game: HubcapGame) -> Bool {
        guard let appID = game.appID else { return false }
        return store.config.apps.contains(appID)
    }

    private func refreshInstalledState() {
        updateInstalledMetric()
        tableView.reloadData()
    }

    private func updateInstalledMetric() {
        let installed = Set(store.config.apps).count
        installedCountLabel?.stringValue = "\(installed) installed"
    }

    private func updateAPIStatus() {
        let hasKey = HubcapCredentialStore.apiKey != nil
        apiStatusIcon?.image = NSImage(
            systemSymbolName: hasKey ? "circle.fill" : "circle",
            accessibilityDescription: hasKey ? "Connected" : "Not connected"
        )
        apiStatusIcon?.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        apiStatusIcon?.contentTintColor = hasKey ? .systemGreen : Colors.secondaryText
        apiStatusTitle?.stringValue = hasKey ? "Connected" : "Not connected"
        apiStatusDetail?.stringValue = hasKey
            ? "Hubcap access is ready."
            : "Add an access key in Settings."
    }

    private func resultSummary(count: Int, search: String) -> String {
        guard search.isEmpty == false else { return "\(count) shown" }
        return "\(count) result(s)"
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

        apiSettingsButton.isEnabled = !busy
        searchField.isEnabled = true
        refreshButton.isEnabled = !busy
        tableView.isEnabled = !busy

        loadMoreButton.isEnabled =
            !busy &&
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
