import AppKit
import ServiceManagement
import RainCore
@preconcurrency import CoreLocation

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private weak var app: AppDelegate?
    private let preview: Bool
    private var selectedTab = 0
    private var sidebarButtons: [NSButton] = []
    private var contentStack = NSStackView()
    private var scrollView = NSScrollView()
    private var stateRunningLabel = NSTextField(labelWithString: "")
    private var stateRenderingLabel = NSTextField(labelWithString: "")
    private var paneTitleLabel = NSTextField(labelWithString: "")
    private var paneSubtitleLabel = NSTextField(labelWithString: "")
    private var languagePopup: NSPopUpButton?
    private var loginButton: NSButton?
    private var modePopup: NSPopUpButton?
    private var allDisplaysButton: NSButton?
    private var displayButtons: [NSButton] = []
    private var missionControlButton: NSButton?
    private var shortcutRecorder: ShortcutRecorder?
    private var shortcutDirty = false
    private var shortcutMessage: String?
    private var shortcutStatusLabel: NSTextField?
    private var stopToggleShortcutRecorder: ShortcutRecorder?
    private var stopToggleShortcutDirty = false
    private var stopToggleShortcutMessage: String?
    private var stopToggleShortcutStatusLabel: NSTextField?
    private var strengthPopup: NSPopUpButton?
    private var randomIntervalPopup: NSPopUpButton?
    private var randomIntervalRow: NSView?
    private var dropScalePopup: NSPopUpButton?
    private var wipeAnimationPopup: NSPopUpButton?
    private var frameRatePopup: NSPopUpButton?
    private var renderQualityPopup: NSPopUpButton?
    private var refractionButton: NSButton?
    private var chromaticAberrationPopup: NSPopUpButton?
    private var exclusionButtons: [NSButton] = []
    private var locationLabel: NSTextField?
    private var locationStatusLabel: NSTextField?
    private var locationPermissionLabel: NSTextField?
    private var capturePermissionLabel: NSTextField?
    private var captureStatusLabel: NSTextField?
    private var knownDisplayIDs: Set<String> = []
    private var knownExcludedIDs: Set<String> = []
    private var isRebuilding = false
    private var stateObserver: NSObjectProtocol?
    private var languageObserver: NSObjectProtocol?

    private let tabs: [(String, String, String, String)] = [
        ("gearshape", "General", "一般", "General settings"),
        ("command", "Shortcuts", "ショートカット", "Keyboard shortcuts"),
        ("rectangle.slash", "Exclusions", "除外", "Excluded apps"),
        ("cloud.rain", "Rain", "雨", "Rain appearance"),
        ("location", "Location", "場所", "Weather location"),
        ("checkmark.shield", "Setup", "セットアップ", "Permissions and setup"),
        ("info.circle", "About", "このアプリについて", "About Rainy Screen")
    ]

    init(app: AppDelegate, preview: Bool = false) {
        self.app = app
        self.preview = preview
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Rainy Screen"
        // Rain overlays sit just below the status-window level. Keep settings
        // above them so enabling rain cannot cover the controls.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)))
        window.minSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        setupUI()
        stateObserver = NotificationCenter.default.addObserver(forName: .rainyScreenStateDidChange,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshFromApp() }
        }
        languageObserver = NotificationCenter.default.addObserver(forName: .rainyScreenLanguageDidChange,
                                                                    object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuildCurrentPane() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let stateObserver { NotificationCenter.default.removeObserver(stateObserver) }
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        refreshFromApp()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshFromApp()
    }

    func refreshFromApp() {
        guard let app else { return }
        let snapshot = app.settingsSnapshot()
        if !isRebuilding {
            let displayIDs = Set(app.settingsDisplayOptions().map(\.id))
            let excludedIDs = Set(app.settingsAvailableApps().map(\.id))
            let listsChanged = displayIDs != knownDisplayIDs || excludedIDs != knownExcludedIDs
            knownDisplayIDs = displayIDs; knownExcludedIDs = excludedIDs
            if listsChanged && (selectedTab == 0 || selectedTab == 2) {
                rebuildCurrentPane()
                return
            }
        }
        stateRunningLabel.stringValue = statusRunningText(snapshot.running)
        stateRenderingLabel.stringValue = statusRenderingText(snapshot.rendering)
        syncControls(snapshot)
    }

    func runSmokeTest() {
        guard let app, let window, let contentView = window.contentView else { return }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/settings-preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let languages: [(L10n.Preference, String)] = [(.english, "en"), (.japanese, "ja")]
        var snapshotCount = 0
        for (language, languageCode) in languages {
            app.settingsSetLanguage(language)
            for index in tabs.indices {
                selectTab(index)
                window.displayIfNeeded()
                contentView.displayIfNeeded()
                let bounds = contentView.bounds
                guard let rep = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
                    fputs("SETTINGS_SMOKE_FAILED: could not create pane image\n", stderr)
                    exit(1)
                }
                contentView.cacheDisplay(in: bounds, to: rep)
                guard let image = rep.cgImage else {
                    fputs("SETTINGS_SMOKE_FAILED: could not create pane image\n", stderr)
                    exit(1)
                }
                guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    fputs("SETTINGS_SMOKE_FAILED: could not encode pane image\n", stderr)
                    exit(1)
                }
                let file = directory.appendingPathComponent("\(languageCode)-\(index + 1)-\(tabs[index].1.lowercased()).png")
                do { try data.write(to: file); snapshotCount += 1 }
                catch { fputs("SETTINGS_SMOKE_FAILED: \(error)\n", stderr); exit(1) }
            }
        }
        guard snapshotCount == 14 else {
            fputs("SETTINGS_SMOKE_FAILED: expected 14 snapshots, got \(snapshotCount)\n", stderr)
            exit(1)
        }
        print("SETTINGS_SMOKE_OK: \(snapshotCount) pane snapshots saved to \(directory.path)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
    }

    private func setupUI() {
        guard let window, let root = window.contentView else { return }
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        split.addArrangedSubview(makeSidebar())
        split.addArrangedSubview(makeMainPane())
        split.setPosition(210, ofDividerAt: 0)
        selectTab(0)
    }

    private func makeSidebar() -> NSView {
        let sidebar = NSView()
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 24)
        ])

        let appLabel = NSTextField(labelWithString: "Rainy Screen")
        appLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        appLabel.textColor = .labelColor
        appLabel.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(appLabel)
        stack.setCustomSpacing(18, after: appLabel)

        for (index, tab) in tabs.enumerated() {
            let button = NSButton(title: tab.1, target: self, action: #selector(sidebarSelection(_:)))
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 7
            button.heightAnchor.constraint(equalToConstant: 38).isActive = true
            button.alignment = .left
            button.image = NSImage(systemSymbolName: tab.0, accessibilityDescription: tab.1)
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = .secondaryLabelColor
            button.identifier = NSUserInterfaceItemIdentifier("tab-\(index)")
            button.setAccessibilityLabel(L10n.text(tab.2, tab.1))
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 178).isActive = true
            stack.addArrangedSubview(button)
            sidebarButtons.append(button)
        }
        return sidebar
    }

    private func makeMainPane() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView()
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        header.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)
        paneTitleLabel.font = .systemFont(ofSize: 26, weight: .bold)
        paneTitleLabel.textColor = .labelColor
        paneSubtitleLabel.font = .systemFont(ofSize: 13)
        paneSubtitleLabel.textColor = .secondaryLabelColor
        header.addArrangedSubview(paneTitleLabel)
        header.addArrangedSubview(paneSubtitleLabel)

        let stateCard = NSStackView()
        stateCard.orientation = .horizontal
        stateCard.spacing = 18
        stateCard.alignment = .centerY
        stateCard.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        stateCard.wantsLayer = true
        stateCard.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        stateCard.layer?.cornerRadius = 9
        stateCard.layer?.borderWidth = 1
        stateCard.layer?.borderColor = NSColor.separatorColor.cgColor
        stateCard.translatesAutoresizingMaskIntoConstraints = false
        stateRunningLabel.font = .systemFont(ofSize: 12, weight: .medium)
        stateRenderingLabel.font = .systemFont(ofSize: 12, weight: .medium)
        stateCard.addArrangedSubview(stateRunningLabel)
        stateCard.addArrangedSubview(stateRenderingLabel)
        container.addSubview(stateCard)

        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        contentStack.orientation = .vertical
        contentStack.distribution = .fill
        contentStack.alignment = .leading
        contentStack.spacing = 16
        contentStack.edgeInsets = NSEdgeInsets(top: 10, left: 2, bottom: 28, right: 18)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        let document = SettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(contentStack)
        scrollView.documentView = document
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: document.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentStack.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -18),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 28),
            stateCard.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            stateCard.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor),
            stateCard.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            scrollView.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: stateCard.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    @objc private func sidebarSelection(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue.replacingOccurrences(of: "tab-", with: ""),
              let index = Int(raw) else { return }
        selectTab(index)
    }

    private func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedTab = index
        updateLanguageChrome()
        for (buttonIndex, button) in sidebarButtons.enumerated() {
            button.state = buttonIndex == index ? .on : .off
            button.contentTintColor = buttonIndex == index ? .controlAccentColor : .secondaryLabelColor
            button.layer?.backgroundColor = buttonIndex == index
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22).cgColor
                : NSColor.clear.cgColor
        }
        paneTitleLabel.stringValue = L10n.text(tabs[index].2, tabs[index].1)
        paneSubtitleLabel.stringValue = tabSubtitle(index)
        rebuildCurrentPane()
    }

    private func updateLanguageChrome() {
        for (index, button) in sidebarButtons.enumerated() where tabs.indices.contains(index) {
            button.title = L10n.text(tabs[index].2, tabs[index].1)
            button.setAccessibilityLabel(button.title)
        }
        if tabs.indices.contains(selectedTab) {
            paneTitleLabel.stringValue = L10n.text(tabs[selectedTab].2, tabs[selectedTab].1)
            paneSubtitleLabel.stringValue = tabSubtitle(selectedTab)
        }
    }

    private func tabSubtitle(_ index: Int) -> String {
        let japanese = ["一般設定", "キーボードショートカット", "除外するアプリ", "雨の表示設定", "天気を取得する場所", "権限とセットアップ", "Rainy Screenについて"]
        guard tabs.indices.contains(index), japanese.indices.contains(index) else { return "" }
        return L10n.text(japanese[index], tabs[index].3)
    }

    func rebuildCurrentPane() {
        isRebuilding = true
        updateLanguageChrome()
        while let view = contentStack.arrangedSubviews.last {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        languagePopup = nil; loginButton = nil; modePopup = nil; allDisplaysButton = nil
        displayButtons.removeAll(); missionControlButton = nil; shortcutRecorder = nil; shortcutDirty = false; shortcutMessage = nil
        shortcutStatusLabel = nil; strengthPopup = nil; randomIntervalPopup = nil; randomIntervalRow = nil
        dropScalePopup = nil; wipeAnimationPopup = nil; frameRatePopup = nil; refractionButton = nil
        chromaticAberrationPopup = nil
        exclusionButtons.removeAll(); locationLabel = nil; locationStatusLabel = nil
        locationPermissionLabel = nil; capturePermissionLabel = nil; captureStatusLabel = nil

        switch selectedTab {
        case 0: buildGeneral()
        case 1: buildShortcuts()
        case 2: buildExclusions()
        case 3: buildRain()
        case 4: buildLocation()
        case 5: buildSetup()
        default: buildAbout()
        }
        refreshFromApp()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        isRebuilding = false
    }

    @discardableResult private func addCard(_ title: String, _ subtitle: String? = nil, contents: [NSView]) -> NSStackView {
        let card = NSStackView()
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 10
        card.edgeInsets = NSEdgeInsets(top: 15, left: 16, bottom: 15, right: 16)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        card.addArrangedSubview(heading)
        if let subtitle {
            let detail = NSTextField(wrappingLabelWithString: subtitle)
            detail.font = .systemFont(ofSize: 12)
            detail.textColor = .secondaryLabelColor
            card.addArrangedSubview(detail)
        }
        for view in contents { card.addArrangedSubview(view) }
        contentStack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        return card
    }

    private func row(_ label: String, control: NSView, detail: String? = nil) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        let text = NSTextField(labelWithString: label)
        text.font = .systemFont(ofSize: 13)
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(text)
        if let detail {
            let help = NSTextField(labelWithString: detail)
            help.font = .systemFont(ofSize: 11)
            help.textColor = .secondaryLabelColor
            help.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(help)
        }
        row.addArrangedSubview(control)
        return row
    }

    private func makeCheckbox(_ title: String, action: Selector? = nil) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: action == nil ? nil : self, action: action)
        button.font = .systemFont(ofSize: 13)
        return button
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    private func buildGeneral() {
        let language = NSPopUpButton()
        language.addItems(withTitles: [L10n.text("システムに従う", "System"), "日本語", "English"])
        language.target = self; language.action = #selector(languageChanged(_:))
        languagePopup = language
        addCard(L10n.text("言語", "Language"), contents: [row(L10n.text("表示言語", "Display language"), control: language)])

        let login = makeCheckbox(L10n.text("ログイン時に起動", "Launch at login"), action: #selector(loginChanged(_:)))
        loginButton = login
        let mode = NSPopUpButton()
        mode.addItems(withTitles: [L10n.text("ウェザーモード", "Weather Mode"), L10n.text("レイニーモード", "Rainy Mode"), L10n.text("停止", "Stop")])
        mode.target = self; mode.action = #selector(modeChanged(_:))
        modePopup = mode
        addCard(L10n.text("動作", "Behavior"), contents: [login, row(L10n.text("モード", "Mode"), control: mode)])

        let displayViews: [NSView] = []
        _ = displayViews
        let all = makeCheckbox(L10n.text("すべてのディスプレイ（デフォルト）", "All displays (default)"), action: #selector(allDisplaysChanged(_:)))
        allDisplaysButton = all
        var rows: [NSView] = [all]
        for display in app?.settingsDisplayOptions() ?? [] {
            let button = makeCheckbox(display.name, action: #selector(displayChanged(_:)))
            button.identifier = NSUserInterfaceItemIdentifier("display-\(display.id)")
            displayButtons.append(button)
            rows.append(button)
        }
        addCard(L10n.text("対象ディスプレイ", "Target displays"), L10n.text("雨を表示する画面を選択します。", "Choose where rain is displayed."), contents: rows)

        let mission = makeCheckbox(L10n.text("Mission Control中は雨をリセット", "Reset rain during Mission Control"), action: #selector(missionControlChanged(_:)))
        missionControlButton = mission
        addCard(L10n.text("一時停止", "Pause behavior"), contents: [mission])

        let locationButton = makeButton(L10n.text("位置情報の設定を開く…", "Open Location settings…"), action: #selector(openLocationSettings))
        addCard(L10n.text("権限", "Permissions"), L10n.text("現在地の天気を使う場合に必要です。", "Required when using the current location for weather."), contents: [locationButton])
    }

    private func buildShortcuts() {
        let fixed = NSTextField(wrappingLabelWithString: L10n.text("停止: ⌃⌥⌘R（固定）", "Stop: ⌃⌥⌘R (fixed)"))
        fixed.font = .systemFont(ofSize: 13)
        let recorder = ShortcutRecorder(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
        recorder.isEditable = false
        recorder.alignment = .center
        recorder.placeholderString = L10n.text("クリックしてキーを押す", "Click and press a key")
        recorder.onChange = { [weak self, weak recorder] in
            self?.shortcutDirty = true
            self?.shortcutMessage = recorder?.shortcut == nil
                ? L10n.text("修飾キーを含むショートカットを入力してください。", "Include at least one modifier key.") : nil
            self?.shortcutStatusLabel?.stringValue = self?.shortcutMessage ?? ""
        }
        shortcutRecorder = recorder
        let register = makeButton(L10n.text("登録", "Register"), action: #selector(registerShortcut))
        let clear = makeButton(L10n.text("登録を解除", "Clear"), action: #selector(clearShortcut))
        let buttons = NSStackView(views: [register, clear]); buttons.spacing = 8
        let status = NSTextField(wrappingLabelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        shortcutStatusLabel = status
        addCard(L10n.text("拭き上げショートカット", "Wipe shortcut"), L10n.text("ほかのアプリを操作中も窓を拭き上げます。", "Wipes the window while another app is active."), contents: [fixed, row(L10n.text("ショートカット", "Shortcut"), control: recorder), buttons, status])

        let stopToggleRecorder = ShortcutRecorder(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
        stopToggleRecorder.isEditable = false
        stopToggleRecorder.alignment = .center
        stopToggleRecorder.placeholderString = L10n.text("クリックしてキーを押す", "Click and press a key")
        stopToggleRecorder.onChange = { [weak self, weak stopToggleRecorder] in
            self?.stopToggleShortcutDirty = true
            self?.stopToggleShortcutMessage = stopToggleRecorder?.shortcut == nil
                ? L10n.text("修飾キーを含めてください。", "Include a modifier key.") : nil
            self?.stopToggleShortcutStatusLabel?.stringValue = self?.stopToggleShortcutMessage ?? ""
        }
        stopToggleShortcutRecorder = stopToggleRecorder
        let stopToggleRegister = makeButton(L10n.text("登録", "Register"), action: #selector(registerStopToggleShortcut))
        let stopToggleClear = makeButton(L10n.text("登録を解除", "Clear"), action: #selector(clearStopToggleShortcut))
        let stopToggleButtons = NSStackView(views: [stopToggleRegister, stopToggleClear]); stopToggleButtons.spacing = 8
        let stopToggleStatus = NSTextField(wrappingLabelWithString: "")
        stopToggleStatus.font = .systemFont(ofSize: 11)
        stopToggleStatus.textColor = .secondaryLabelColor
        stopToggleShortcutStatusLabel = stopToggleStatus
        addCard(L10n.text("停止トグルショートカット", "Stop toggle shortcut"),
                L10n.text("雨の停止と再開を切り替えます。", "Toggles rain off and on."),
                contents: [row(L10n.text("ショートカット", "Shortcut"), control: stopToggleRecorder), stopToggleButtons, stopToggleStatus])
    }

    private func buildExclusions() {
        let add = makeButton(L10n.text("アプリを追加…", "Add application…"), action: #selector(addExcludedApp))
        var rows: [NSView] = [add]
        let apps = app?.settingsAvailableApps() ?? []
        if apps.isEmpty {
            rows.append(NSTextField(labelWithString: L10n.text("現在起動中のアプリはありません。", "No running applications found.")))
        }
        for appInfo in apps {
            let button = makeCheckbox(appInfo.name, action: #selector(excludedAppChanged(_:)))
            button.identifier = NSUserInterfaceItemIdentifier("excluded-\(appInfo.id)")
            button.toolTip = appInfo.id
            exclusionButtons.append(button)
            rows.append(button)
        }
        let clear = makeButton(L10n.text("すべて解除", "Clear all"), action: #selector(clearExcludedApps))
        rows.append(clear)
        addCard(L10n.text("除外するアプリ", "Excluded applications"), L10n.text("登録したアプリのウインドウを雨の描画から除外します。", "Registered application windows stay clear of the rain layer."), contents: rows)
    }

    private func buildRain() {
        let strength = NSPopUpButton()
        for option in [Float(0.35), 0.8, 1.4, 2.4, 3.8, 5.6] {
            strength.addItem(withTitle: strengthName(option))
            strength.lastItem?.representedObject = option
        }
        strength.addItem(withTitle: L10n.text("ランダム", "Random")); strength.lastItem?.representedObject = "random"; strength.lastItem?.tag = 99
        strength.target = self; strength.action = #selector(strengthChanged(_:)); strengthPopup = strength

        let interval = NSPopUpButton()
        interval.addItems(withTitles: [L10n.text("頻繁（15秒）", "Frequent (15 sec)"), L10n.text("短め（30秒）", "Short (30 sec)"), L10n.text("標準（1分）", "Standard (1 min)"), L10n.text("ゆったり（3分）", "Relaxed (3 min)"), L10n.text("のんびり（5分）", "Slow (5 min)")])
        interval.target = self; interval.action = #selector(randomIntervalChanged(_:)); randomIntervalPopup = interval
        let intervalRow = row(L10n.text("ランダム切替間隔", "Random interval"), control: interval)
        randomIntervalRow = intervalRow

        let size = NSPopUpButton()
        for value in [Float(1), 1.25, 1.5, 1.75, 2, 2.5] { size.addItem(withTitle: String(format: "%.3gx", value)); size.lastItem?.representedObject = value }
        size.target = self; size.action = #selector(dropScaleChanged(_:)); dropScalePopup = size
        let wipe = NSPopUpButton()
        // Keep this as a popup so future physically distinct runoff models can
        // be added without changing the settings layout. The old screen-space
        // wipes are intentionally no longer exposed.
        wipe.addItem(withTitle: L10n.text("横方向（左→右）", "Horizontal (left to right)")); wipe.item(at: 0)?.tag = WipeAnimation.drain.rawValue
        wipe.addItem(withTitle: L10n.text("縦方向（上→下）", "Vertical (top to bottom)")); wipe.item(at: 1)?.tag = WipeAnimation.vertical.rawValue
        wipe.target = self; wipe.action = #selector(wipeAnimationChanged(_:)); wipeAnimationPopup = wipe
        let fps = NSPopUpButton(); fps.addItems(withTitles: ["24 FPS", "30 FPS", "60 FPS"])
        fps.item(at: 0)?.tag = 24; fps.item(at: 1)?.tag = 30; fps.item(at: 2)?.tag = 60
        fps.target = self; fps.action = #selector(frameRateChanged(_:)); frameRatePopup = fps
        let quality = NSPopUpButton()
        quality.addItem(withTitle: L10n.text("ハイクオリティ（最高水準）", "High quality (maximum)")); quality.item(at: 0)?.tag = RainRenderQuality.high.rawValue
        quality.addItem(withTitle: L10n.text("バランス", "Balanced")); quality.item(at: 1)?.tag = RainRenderQuality.balanced.rawValue
        quality.addItem(withTitle: L10n.text("軽量", "Performance")); quality.item(at: 2)?.tag = RainRenderQuality.light.rawValue
        quality.target = self; quality.action = #selector(renderQualityChanged(_:)); renderQualityPopup = quality
        let refract = makeCheckbox(L10n.text("背景の屈折・ぼかし", "Background refraction and blur"), action: #selector(refractionChanged(_:)))
        refractionButton = refract
        let aberration = NSPopUpButton()
        for value in ChromaticAberration.levels {
            let title = value == 0 ? L10n.text("オフ", "Off")
                : value == 1 ? L10n.text("1倍（標準）", "1× (Default)")
                : L10n.text("\(Int(value))倍", "\(Int(value))×")
            aberration.addItem(withTitle:title)
            aberration.lastItem?.tag = Int(value)
        }
        aberration.target = self; aberration.action = #selector(chromaticAberrationChanged(_:))
        aberration.toolTip = L10n.text("水滴の輪郭に出る色のずれの強さ。背景の屈折と画面収録の許可が必要です。", "Color separation at water edges. Requires background refraction and Screen Recording permission.")
        chromaticAberrationPopup = aberration
        addCard(L10n.text("雨の見た目", "Rain appearance"), contents: [row(L10n.text("雨の強さ", "Rain intensity"), control: strength), intervalRow, row(L10n.text("雨粒のサイズ", "Raindrop size"), control: size), row(L10n.text("吹き上げ", "Runoff animation"), control: wipe), row(L10n.text("描画FPS", "Frame rate"), control: fps), row(L10n.text("描画品質", "Render quality"), control: quality, detail: L10n.text("衝突計算と雨筋履歴の精度", "Collision and trail-history fidelity")), refract, row(L10n.text("色収差", "Chromatic aberration"),control:aberration)])
    }

    private func buildLocation() {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 14, weight: .medium); locationLabel = label
        let status = NSTextField(wrappingLabelWithString: "")
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor; locationStatusLabel = status
        let current = makeButton(L10n.text("現在地を使う", "Use current location"), action: #selector(useCurrentLocation))
        let select = makeButton(L10n.text("場所を指定…", "Choose location…"), action: #selector(selectLocation))
        let refresh = makeButton(L10n.text("天気を今すぐ更新", "Refresh weather now"), action: #selector(refreshWeather))
        let buttons = NSStackView(views: [current, select, refresh]); buttons.orientation = .vertical; buttons.alignment = .leading; buttons.spacing = 8
        let card = addCard(L10n.text("天気の場所", "Weather location"), L10n.text("Open-Meteoから取得する天気の地点です。", "The location used for Open-Meteo weather data."), contents: [label, status, buttons])
        label.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -32).isActive = true
        status.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -32).isActive = true
    }

    private func buildSetup() {
        let location = NSTextField(wrappingLabelWithString: "")
        location.font = .systemFont(ofSize: 13); locationPermissionLabel = location
        let locationButton = makeButton(L10n.text("位置情報の設定を開く…", "Open Location settings…"), action: #selector(openLocationSettings))
        let capture = NSTextField(wrappingLabelWithString: "")
        capture.font = .systemFont(ofSize: 13); capturePermissionLabel = capture
        let captureStatus = NSTextField(wrappingLabelWithString: "")
        captureStatus.font = .systemFont(ofSize: 11)
        captureStatus.textColor = .secondaryLabelColor
        captureStatusLabel = captureStatus
        let requestCapture = makeButton(L10n.text("画面収録の許可を要求", "Request Screen Recording permission"), action: #selector(requestCapturePermission))
        let captureButton = makeButton(L10n.text("画面収録の設定を開く…", "Open Screen Recording settings…"), action: #selector(openCaptureSettings))
        addCard(L10n.text("位置情報", "Location"), L10n.text("現在地モードの許可状態です。", "Permission used by current location mode."), contents: [location, locationButton])
        addCard(L10n.text("画面収録", "Screen Recording"), L10n.text("背景の屈折・ぼかしに必要です。", "Required for background refraction and blur."), contents: [capture, captureStatus, requestCapture, captureButton])
    }

    private func buildAbout() {
        let text = NSTextView(frame: .zero)
        text.isEditable = false; text.isSelectable = true; text.drawsBackground = false
        text.font = .systemFont(ofSize: 13); text.textColor = .labelColor
        text.string = aboutText()
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.heightAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
        let link = makeButton(L10n.text("Open-Meteoを開く", "Open Open-Meteo"), action: #selector(openAttribution))
        let help = makeButton(L10n.text("使い方・権限について", "Usage and permissions"), action: #selector(showHelp))
        let card = addCard(L10n.text("Rainy Screenについて", "About Rainy Screen"), contents: [text, NSStackView(views: [help, link])])
        text.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -32).isActive = true
    }

    private func strengthName(_ value: Float) -> String {
        switch value {
        case 0.35: return L10n.text("霧雨（細粒・結露）", "Mist")
        case 0.8: return L10n.text("弱", "Light")
        case 1.4: return L10n.text("中（これまでの強さ）", "Medium")
        case 2.4: return L10n.text("強", "Strong")
        case 3.8: return L10n.text("大雨", "Heavy")
        default: return L10n.text("豪雨（大粒・高速）", "Downpour")
        }
    }

    private func aboutText() -> String {
        L10n.text("Rainy Screenは、デスクトップを雨の窓のように見せるメニューバーアプリです。\n\n使い方\n・Weather Modeは指定地点の天気に連動します。\n・Rainy Modeは天気に関係なく雨を表示します。\n・カーソルを動かすと窓を拭けます。\n\n権限\n・位置情報: 現在地の天気を取得するために使用します。\n・画面収録: 背景の屈折・ぼかしに使用します。画面は保存・送信しません。\n\n使用ライブラリ\n・Apple Metal / MetalKit / Core Location\n・Open-Meteo weather API", "Rainy Screen is a menu bar app that turns your desktop into a rainy window.\n\nUsage\n• Weather Mode follows the weather at the selected location.\n• Rainy Mode displays rain regardless of the weather.\n• Move the cursor to wipe the window.\n\nPermissions\n• Location: used to retrieve weather for your current location.\n• Screen Recording: used for background refraction and blur. The screen is not saved or uploaded.\n\nLibraries\n• Apple Metal / MetalKit / Core Location\n• Open-Meteo weather API")
    }

    private func syncControls(_ snapshot: RainyScreenSettingsSnapshot) {
        stateRunningLabel.stringValue = statusRunningText(snapshot.running)
        stateRenderingLabel.stringValue = statusRenderingText(snapshot.rendering)
        languagePopup?.selectItem(at: [L10n.Preference.system, .japanese, .english].firstIndex(of: snapshot.language) ?? 0)
        loginButton?.state = snapshot.loginEnabled ? .on : .off
        modePopup?.selectItem(at: ["auto", "demo", "off"].firstIndex(of: snapshot.mode) ?? 0)
        allDisplaysButton?.state = snapshot.allDisplays ? .on : .off
        for button in displayButtons {
            let id = button.identifier?.rawValue.replacingOccurrences(of: "display-", with: "") ?? ""
            button.state = snapshot.allDisplays || snapshot.selectedDisplayIDs.contains(id) ? .on : .off
        }
        missionControlButton?.state = snapshot.resetOnMissionControl ? .on : .off
        if let recorder = shortcutRecorder, !shortcutDirty || recorder.window?.firstResponder !== recorder {
            recorder.shortcut = snapshot.wipeShortcut
            recorder.stringValue = snapshot.wipeShortcut?.label ?? ""
        }
        if !shortcutDirty {
            shortcutStatusLabel?.stringValue = shortcutMessage ?? (snapshot.wipeShortcut == nil ? L10n.text("未登録", "Not registered") : "")
        }
        if let recorder = stopToggleShortcutRecorder, !stopToggleShortcutDirty || recorder.window?.firstResponder !== recorder {
            recorder.shortcut = snapshot.stopToggleShortcut
            recorder.stringValue = snapshot.stopToggleShortcut?.label ?? ""
        }
        if !stopToggleShortcutDirty {
            stopToggleShortcutStatusLabel?.stringValue = stopToggleShortcutMessage ?? (snapshot.stopToggleShortcut == nil ? L10n.text("未登録", "Not registered") : "")
        }
        if let popup = strengthPopup {
            if snapshot.randomStrength { popup.selectItem(withTag: 99) }
            else { popup.selectItems(with: { ($0.representedObject as? NSNumber)?.floatValue ?? -1 }, matching: snapshot.strength) }
        }
        randomIntervalPopup?.selectItem(at: snapshot.randomStrengthIntervalIndex)
        randomIntervalRow?.isHidden = !snapshot.randomStrength
        dropScalePopup?.selectItems(with: { ($0.representedObject as? NSNumber)?.floatValue ?? -1 }, matching: snapshot.dropScale)
        wipeAnimationPopup?.selectItem(withTag: snapshot.wipeAnimation.rawValue)
        frameRatePopup?.selectItem(withTag: snapshot.frameRate)
        renderQualityPopup?.selectItem(withTag: snapshot.renderQuality.rawValue)
        refractionButton?.state = snapshot.refraction ? .on : .off
        chromaticAberrationPopup?.selectItem(withTag:Int(snapshot.chromaticAberration))
        chromaticAberrationPopup?.isEnabled = snapshot.refraction
        for button in exclusionButtons {
            let id = button.identifier?.rawValue.replacingOccurrences(of: "excluded-", with: "") ?? ""
            button.state = snapshot.excludedAppBundleIDs.contains(id) ? .on : .off
        }
        locationLabel?.stringValue = snapshot.usesManualLocation
            ? L10n.text("指定地点: \(snapshot.locationTitle)", "Selected location: \(snapshot.locationTitle)")
            : L10n.text("現在地（GPS / Wi-Fi）", "Current location (GPS / Wi-Fi)")
        locationStatusLabel?.stringValue = snapshot.weatherLabel
        locationPermissionLabel?.stringValue = permissionLocationText(snapshot.locationAuthorization)
        capturePermissionLabel?.stringValue = snapshot.captureAuthorized
            ? L10n.text("許可済み", "Allowed") : L10n.text("未許可", "Not allowed")
        captureStatusLabel?.stringValue = snapshot.captureMessage
            ?? L10n.text("背景取得フレーム: \(snapshot.captureFrameSummary)", "Background capture frames: \(snapshot.captureFrameSummary)")
    }

    private func permissionLocationText(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .authorized, .authorizedAlways: return L10n.text("許可済み", "Allowed")
        case .denied: return L10n.text("拒否", "Denied")
        case .restricted: return L10n.text("制限されています", "Restricted")
        default: return L10n.text("未確認", "Not determined")
        }
    }

    private func statusRunningText(_ running: Bool) -> String {
        L10n.text("状態: \(running ? "稼働中" : "停止中")", "Status: \(running ? "Running" : "Stopped")")
    }

    private func statusRenderingText(_ rendering: Bool) -> String {
        L10n.text("雨: \(rendering ? "描画中" : "未描画")", "Rain: \(rendering ? "Rendering" : "Not Rendering")")
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        let values: [L10n.Preference] = [.system, .japanese, .english]
        guard values.indices.contains(sender.indexOfSelectedItem), let app else { return }
        app.settingsSetLanguage(values[sender.indexOfSelectedItem])
    }

    @objc private func loginChanged(_ sender: NSButton) { app?.settingsSetLogin(sender.state == .on) }
    @objc private func modeChanged(_ sender: NSPopUpButton) {
        app?.settingsSetMode(["auto", "demo", "off"][max(0, min(2, sender.indexOfSelectedItem))])
    }
    @objc private func allDisplaysChanged(_ sender: NSButton) { app?.settingsSetAllDisplays(sender.state == .on) }
    @objc private func displayChanged(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue.replacingOccurrences(of: "display-", with: "") else { return }
        app?.settingsToggleDisplay(id)
    }
    @objc private func missionControlChanged(_ sender: NSButton) { app?.settingsSetMissionControlReset(sender.state == .on) }
    @objc private func registerShortcut() {
        guard let shortcut = shortcutRecorder?.shortcut else { return }
        let error = app?.settingsRegisterWipeShortcut(shortcut)
        if error == nil { shortcutDirty = false }
        shortcutMessage = error ?? L10n.text("ショートカットを登録しました。", "Shortcut registered.")
        shortcutStatusLabel?.stringValue = shortcutMessage ?? ""
    }
    @objc private func clearShortcut() { shortcutDirty = false; shortcutMessage = nil; app?.settingsClearWipeShortcut() }
    @objc private func registerStopToggleShortcut() {
        guard let shortcut = stopToggleShortcutRecorder?.shortcut else { return }
        let error = app?.settingsRegisterStopToggleShortcut(shortcut)
        if error == nil { stopToggleShortcutDirty = false }
        stopToggleShortcutMessage = error ?? L10n.text("停止トグルショートカットを登録しました。", "Stop toggle shortcut registered.")
        stopToggleShortcutStatusLabel?.stringValue = stopToggleShortcutMessage ?? ""
    }
    @objc private func clearStopToggleShortcut() {
        stopToggleShortcutDirty = false; stopToggleShortcutMessage = nil; app?.settingsClearStopToggleShortcut()
    }
    @objc private func addExcludedApp() { app?.settingsAddExcludedApp() }
    @objc private func excludedAppChanged(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue.replacingOccurrences(of: "excluded-", with: "") else { return }
        app?.settingsToggleExcludedApp(id)
    }
    @objc private func clearExcludedApps() { app?.settingsClearExcludedApps() }
    @objc private func strengthChanged(_ sender: NSPopUpButton) {
        if sender.selectedItem?.representedObject as? String == "random" { app?.settingsSetRandomStrength(true) }
        else if let value = (sender.selectedItem?.representedObject as? NSNumber)?.floatValue { app?.settingsSetStrength(value) }
    }
    @objc private func randomIntervalChanged(_ sender: NSPopUpButton) { app?.settingsSetRandomInterval(sender.indexOfSelectedItem) }
    @objc private func dropScaleChanged(_ sender: NSPopUpButton) {
        if let value = (sender.selectedItem?.representedObject as? NSNumber)?.floatValue { app?.settingsSetDropScale(value) }
    }
    @objc private func wipeAnimationChanged(_ sender: NSPopUpButton) {
        app?.settingsSetWipeAnimation(WipeAnimation(rawValue: sender.selectedItem?.tag ?? 0) ?? .drain)
    }
    @objc private func frameRateChanged(_ sender: NSPopUpButton) { app?.settingsSetFrameRate([24, 30, 60][max(0, min(2, sender.indexOfSelectedItem))]) }
    @objc private func renderQualityChanged(_ sender: NSPopUpButton) {
        app?.settingsSetRenderQuality(RainRenderQuality(rawValue:sender.selectedItem?.tag ?? 0) ?? .high)
    }
    @objc private func refractionChanged(_ sender: NSButton) { app?.settingsSetRefraction(sender.state == .on) }
    @objc private func chromaticAberrationChanged(_ sender: NSPopUpButton) {
        app?.settingsSetChromaticAberration(Float(sender.selectedItem?.tag ?? 1))
    }
    @objc private func useCurrentLocation() { app?.settingsUseCurrentLocation() }
    @objc private func selectLocation() { app?.settingsSelectLocation() }
    @objc private func refreshWeather() { app?.settingsRefreshWeather() }
    @objc private func openLocationSettings() { app?.settingsOpenLocationSettings() }
    @objc private func openCaptureSettings() { app?.settingsOpenCaptureSettings() }
    @objc private func requestCapturePermission() { app?.settingsRequestCapturePermission() }
    @objc private func openAttribution() { app?.settingsOpenAttribution() }
    @objc private func showHelp() { app?.settingsShowHelp() }
}

private extension NSPopUpButton {
    func selectItems(with value: (NSMenuItem) -> Float, matching expected: Float) {
        for index in 0..<numberOfItems {
            guard let menuItem = item(at: index), abs(value(menuItem) - expected) < 0.01 else { continue }
            selectItem(at: index); return
        }
    }
}
