import AppKit
import ApplicationServices
import UniformTypeIdentifiers

/// QuitLite'ın tüm ayarlarını barındıran pencere.
/// On-demand oluşturulur; kapanınca GUI süreci sonlanır.
final class SettingsWindowController: NSWindowController, NSWindowDelegate,
                                      NSTableViewDataSource, NSTableViewDelegate {

    private let prefs = Preferences.shared

    private let tableView = NSTableView()
    private var entries: [String] = []

    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let delayValueLabel = NSTextField(labelWithString: "")
    private let listHintLabel = NSTextField(labelWithString: "")
    private var allAppsRadio: NSButton!
    private var whitelistRadio: NSButton!
    private var enabledCheckbox: NSButton!
    private var menuBarCheckbox: NSButton!
    private var statusTimer: Timer?

    private var editingWhitelist: Bool { prefs.mode == .whitelistOnly }

    convenience init() {
        // İçerik ~980pt. Küçük ekranlarda (örn. 13"/14" MacBook) pencere ekrana
        // sığacak yükseklikte açılır; içerik NSScrollView içinde olduğu için
        // taşan kısma kaydırarak erişilir. Pencere yeniden boyutlandırılabilir.
        let desiredHeight: CGFloat = 980
        let fitHeight = (NSScreen.main?.visibleFrame.height ?? desiredHeight) - 40
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: min(desiredHeight, fitHeight)),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "QuitLite Ayarları"
        window.contentMinSize = NSSize(width: 460, height: 320)
        window.contentMaxSize = NSSize(width: 460, height: desiredHeight)
        window.center()
        self.init(window: window)
        window.delegate = self
        buildLayout()
        reloadList()
        updateStatus()
        // İzin yoksa sistem iznini hemen iste — kullanıcı uygulamayı açtığı an
        // izin penceresi çıkar ve QuitLite Erişilebilirlik listesine eklenir.
        requestAccessibilityIfNeeded()
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
        statusTimer = timer
    }

    // MARK: - Yerleşim

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        // İçerik bir NSScrollView içine alınır: pencere küçük ekranda tüm
        // içeriği gösteremese bile her denetime kaydırarak erişilebilir.
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])

        // --- Durum ---
        stack.addArrangedSubview(sectionHeader("Durum"))

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.widthAnchor.constraint(equalToConstant: 420).isActive = true
        stack.addArrangedSubview(statusLabel)

        let axButton = NSButton(title: "Erişilebilirlik Ayarlarını Aç",
                                target: self, action: #selector(openAccessibilitySettings))
        let revealButton = NSButton(title: "QuitLite.app'i Finder'da Göster",
                                    target: self, action: #selector(revealInFinder))
        axButton.bezelStyle = .rounded
        revealButton.bezelStyle = .rounded
        let axButtons = NSStackView(views: [axButton, revealButton])
        axButtons.orientation = .horizontal
        axButtons.spacing = 8
        stack.addArrangedSubview(axButtons)

        stack.addArrangedSubview(caption("İzin gerekiyor. Erişilebilirlik listesinde "
            + "QuitLite yoksa: '+' düğmesine basıp QuitLite.app'i seçin "
            + "(Finder'da Göster ile bulabilirsiniz), sonra anahtarını açın."))

        stack.addArrangedSubview(separator())

        // --- Genel ---
        stack.addArrangedSubview(sectionHeader("Genel"))

        let agentCheckbox = checkbox("Girişte başlat ve arka planda çalış",
                                     #selector(toggleAgent(_:)), CoreAgent.isRegistered)
        stack.addArrangedSubview(agentCheckbox)

        enabledCheckbox = checkbox("Otomatik kapatmayı uygula",
                                   #selector(toggleEnabled(_:)), prefs.enabled)
        enabledCheckbox.isEnabled = CoreAgent.isRegistered
        stack.addArrangedSubview(enabledCheckbox)

        menuBarCheckbox = checkbox("Menü çubuğunda simge göster",
                                   #selector(toggleMenuBarIcon(_:)), prefs.showMenuBarIcon)
        menuBarCheckbox.isEnabled = CoreAgent.isRegistered
        stack.addArrangedSubview(menuBarCheckbox)

        stack.addArrangedSubview(caption("Menü çubuğuna QuitLite simgesi ekler; "
            + "oradan ayarları açabilir veya QuitLite'tan çıkabilirsiniz. "
            + "Bellek kullanımı ~2,3 MB'den ~10 MB'ye çıkar."))

        let delayTitle = NSTextField(labelWithString: "Kapatma gecikmesi")
        stack.addArrangedSubview(delayTitle)

        let slider = NSSlider(value: prefs.quitDelay,
                              minValue: Preferences.minQuitDelay,
                              maxValue: Preferences.maxQuitDelay,
                              target: self, action: #selector(delayChanged(_:)))
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 300).isActive = true

        delayValueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        delayValueLabel.textColor = .secondaryLabelColor
        updateDelayLabel()

        let delayRow = NSStackView(views: [slider, delayValueLabel])
        delayRow.orientation = .horizontal
        delayRow.spacing = 10
        stack.addArrangedSubview(delayRow)

        stack.addArrangedSubview(caption("Son pencere kapandıktan sonra uygulamanın "
                                         + "kapatılması için beklenen süre."))

        stack.addArrangedSubview(separator())

        // --- Uygulamalar ---
        stack.addArrangedSubview(sectionHeader("Uygulamalar"))

        allAppsRadio = radio("Tüm uygulamalar (kara liste hariç)", #selector(modeChanged(_:)))
        whitelistRadio = radio("Yalnızca izin listesindekiler", #selector(modeChanged(_:)))
        allAppsRadio.tag = QuitMode.allApps.rawValue
        whitelistRadio.tag = QuitMode.whitelistOnly.rawValue
        allAppsRadio.state = editingWhitelist ? .off : .on
        whitelistRadio.state = editingWhitelist ? .on : .off
        stack.addArrangedSubview(allAppsRadio)
        stack.addArrangedSubview(whitelistRadio)

        listHintLabel.font = .systemFont(ofSize: 11)
        listHintLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(listHintLabel)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 200).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 420).isActive = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bundleID"))
        column.width = 400
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 22
        tableView.allowsMultipleSelection = true
        scroll.documentView = tableView
        stack.addArrangedSubview(scroll)

        let addButton = NSButton(title: "Uygulama Ekle…", target: self, action: #selector(addApp))
        let removeButton = NSButton(title: "Kaldır", target: self, action: #selector(removeSelected))
        addButton.bezelStyle = .rounded
        removeButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [addButton, removeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        stack.addArrangedSubview(buttons)

        stack.addArrangedSubview(separator())

        let quitButton = NSButton(title: "QuitLite'tan Çık",
                                  target: self, action: #selector(quitQuitLite))
        quitButton.bezelStyle = .rounded
        stack.addArrangedSubview(quitButton)

        stack.addArrangedSubview(caption("QuitLite'ı tamamen durdurur: arka plan "
            + "çekirdeğini kapatır ve girişte otomatik başlatmayı kaldırır."))
    }

    // MARK: - Yerleşim yardımcıları

    private func sectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: 13)
        return label
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 420).isActive = true
        return label
    }

    private func checkbox(_ title: String, _ action: Selector, _ on: Bool) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = on ? .on : .off
        return button
    }

    private func radio(_ title: String, _ action: Selector) -> NSButton {
        NSButton(radioButtonWithTitle: title, target: self, action: action)
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 420).isActive = true
        return box
    }

    // MARK: - Durum

    private func updateStatus() {
        // GUI ve çekirdek aynı binary (= aynı TCC kimliği) olduğu için izin
        // durumu doğrudan sorgulanabilir; dolaylı/bayatlayabilen bir ayara gerek yok.
        let registered = CoreAgent.isRegistered
        let trusted = AXIsProcessTrusted()
        let core = registered ? "kurulu" : "kurulu değil"
        let ax = trusted ? "verildi ✓" : "GEREKLİ — izin verin"
        statusLabel.stringValue = "Arka plan çekirdeği: \(core)   ·   Erişilebilirlik izni: \(ax)"
    }

    /// Erişilebilirlik izni yoksa sistem iznini ister. Tek binary olduğundan
    /// buradan verilen izin çekirdek için de geçerlidir.
    private func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private func updateDelayLabel() {
        let value = prefs.quitDelay
        delayValueLabel.stringValue = value < 0.05 ? "Anında" : String(format: "%.1f sn", value)
    }

    // MARK: - Eylemler

    @objc private func toggleAgent(_ sender: NSButton) {
        if sender.state == .on {
            CoreAgent.register()
        } else {
            CoreAgent.unregister()
        }
        let registered = CoreAgent.isRegistered
        sender.state = registered ? .on : .off
        enabledCheckbox.isEnabled = registered
        menuBarCheckbox.isEnabled = registered
        updateStatus()
    }

    @objc private func toggleEnabled(_ sender: NSButton) {
        prefs.enabled = (sender.state == .on)
        // Çalışan çekirdek değişikliği gecikmeden görsün diye diske yaz.
        prefs.flush()
    }

    @objc private func toggleMenuBarIcon(_ sender: NSButton) {
        prefs.showMenuBarIcon = (sender.state == .on)
        // Mod kararı çekirdek açılışında verilir. Yeniden başlatmadan önce ayarı
        // diske yaz; yoksa çekirdek relaunch olunca eski değeri okuyabilir.
        prefs.flush()
        CoreAgent.restart()
    }

    /// QuitLite'ı tamamen durdurur: çekirdeği kapatır, LaunchAgent kaydını siler,
    /// GUI'yi sonlandırır. Yıkıcı bir işlem olduğu için önce onay alınır.
    @objc private func quitQuitLite() {
        let alert = NSAlert()
        alert.messageText = "QuitLite tamamen durdurulsun mu?"
        alert.informativeText = "Arka plan çekirdeği kapatılacak ve girişte otomatik "
            + "başlatma kaldırılacak. QuitLite'ı yeniden etkinleştirmek için uygulamayı "
            + "tekrar açıp \"Girişte başlat\"ı işaretleyin."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Durdur ve Çık")
        alert.addButton(withTitle: "Vazgeç")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        CoreAgent.unregister()
        NSApp.terminate(nil)
    }

    @objc private func delayChanged(_ sender: NSSlider) {
        prefs.quitDelay = sender.doubleValue
        updateDelayLabel()
    }

    @objc private func modeChanged(_ sender: NSButton) {
        prefs.mode = QuitMode(rawValue: sender.tag) ?? .allApps
        prefs.flush()
        allAppsRadio.state = sender.tag == QuitMode.allApps.rawValue ? .on : .off
        whitelistRadio.state = sender.tag == QuitMode.whitelistOnly.rawValue ? .on : .off
        reloadList()
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    @objc private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType.application]

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier {
                entries.append(id)
            }
        }
        persistList()
    }

    @objc private func removeSelected() {
        let selected = tableView.selectedRowIndexes
        guard !selected.isEmpty else { return }
        for index in selected.sorted(by: >) where index < entries.count {
            entries.remove(at: index)
        }
        persistList()
    }

    // MARK: - Liste

    private func reloadList() {
        entries = editingWhitelist ? prefs.whitelist : prefs.blacklist
        listHintLabel.stringValue = editingWhitelist
            ? "Yalnızca bu uygulamalar son pencere kapanınca kapatılır."
            : "Bu uygulamalar son pencere kapansa da asla kapatılmaz."
        tableView.reloadData()
    }

    private func persistList() {
        if editingWhitelist {
            prefs.whitelist = entries
        } else {
            prefs.blacklist = entries
        }
        prefs.flush()
        reloadList()
    }

    // MARK: - Tablo

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? {
                let view = NSTableCellView()
                let text = NSTextField(labelWithString: "")
                text.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(text)
                view.textField = text
                NSLayoutConstraint.activate([
                    text.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
                    text.centerYAnchor.constraint(equalTo: view.centerYAnchor)
                ])
                view.identifier = id
                return view
            }()
        cell.textField?.stringValue = entries[row]
        return cell
    }

    func windowWillClose(_ notification: Notification) {
        statusTimer?.invalidate()
        statusTimer = nil
    }
}

/// NSScrollView belge görünümü için: içeriğin üstten aşağı dizilmesi (ve doğru
/// kaydırması) için koordinat sistemi ters çevrilir.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
