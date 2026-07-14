import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var store: AccountStore!
    private var poller: Poller!
    private let menu = NSMenu()
    private let updatedItem = NSMenuItem(title: "Updated —", action: nil, keyEquivalent: "")
    private var appearanceObservation: NSKeyValueObservation?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ note: Notification) {
        // Ставим иконку ПЕРВЫМ делом, чтобы она появилась сразу. AccountStore()
        // синхронно читает Keychain-запись Claude Code — при первом запуске это
        // вызывает диалог доступа, который заблокировал бы поток; к этому моменту
        // иконка уже на экране, так что приложение не выглядит зависшим.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = IconRenderer.image(levels: [])
        menu.delegate = self
        statusItem.menu = menu

        store = AccountStore()
        poller = Poller(store: store)
        poller.onUpdate = { [weak self] _ in self?.render() }
        poller.onAlerts = { events in
            guard UserDefaults.standard.bool(forKey: Self.usageAlertsKey) else { return }
            Notifier.deliver(events)
        }
        rebuildMenu()
        renderIcon()
        poller.start()
        Updates.check(announce: false)

        // Colored (non-template) icons don't auto-retint on light/dark switch like
        // template images do — re-render whenever the effective appearance changes.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.renderIcon() }
        }

        // Конкуренты после закрытой крышки показывают старые цифры, пока юзер сам не
        // откроет меню — опрашиваем сразу по пробуждению. pollNow() уже дедупит вызовы
        // младше 10с, так что это безопасно даже если сон был совсем коротким.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.poller.pollNow() }
        }
    }

    // «Щель под Quit» v2 (12.07): полная пересборка меню, пока оно ОТКРЫТО
    // (poll приходит через menuWillOpen → render), оставляет NSMenu-окну старую
    // высоту — снизу появляется пустое место. Пока меню открыто, строки
    // обновляем на месте (rootView того же NSHostingView), а пересборку
    // откладываем до закрытия.
    private var menuIsOpen = false

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menuIsOpen = true
        // Содержимое сабменю освежается ЗДЕСЬ, до первого показа их окон.
        // Мутация в menuNeedsUpdate (в момент раскрытия) оставляла окну сабменю
        // старую высоту — «щель после Remove», тот же AppKit-квирк, что и щель
        // под Quit при пересборке открытого меню (фикс v2).
        for item in self.menu.items {
            guard let id = item.representedObject as? UUID,
                  let account = store.accounts.first(where: { $0.id == id }),
                  let sub = item.submenu else { continue }
            populateAccountSubmenu(sub, account: account)
        }
        poller.pollNow()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        rebuildMenu()   // подхватить возможные изменения состава аккаунтов
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        for account in store.accounts {
            let item = MenuRowFactory.item(for: account, state: poller.state(for: account.id))
            item.submenu = accountSubmenu(account)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        updatedItem.isEnabled = false
        menu.addItem(updatedItem)
        addAction("Add Claude Account…", #selector(addAccount))
        addAction("Add Claude CLI Profile…", #selector(addClaudeProfile))
        addAction("Add Codex Account…", #selector(addCodexAccount))
        menu.addItem(.separator())
        let login = addAction("Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let alerts = addAction("Usage Alerts", #selector(toggleUsageAlerts))
        alerts.state = UserDefaults.standard.bool(forKey: Self.usageAlertsKey) ? .on : .off
        addAction("Check for Updates…", #selector(checkUpdates))
        addAction("View on GitHub", #selector(openRepo))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit AI Status Bar",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @discardableResult
    private func addAction(_ title: String, _ sel: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func accountSubmenu(_ account: Account) -> NSMenu {
        // Детали окон живут в этом же сабменю (выбор владельца 12.07: «выпадает
        // справа, как Rename/Re-login/Remove», а не системным тултипом).
        // ⚠️ Никакого delegate/menuNeedsUpdate: мутация состава в момент показа
        // ломает высоту окна сабменю; свежесть обеспечивает menuWillOpen.
        let sub = NSMenu()
        populateAccountSubmenu(sub, account: account)
        return sub
    }

    private func populateAccountSubmenu(_ sub: NSMenu, account: Account) {
        sub.removeAllItems()
        addAccountDetails(sub, account: account)
        let rename = NSMenuItem(title: "Rename…", action: #selector(renameAccount(_:)), keyEquivalent: "")
        rename.target = self; rename.representedObject = account.id
        sub.addItem(rename)
        if account.kind == .claudeOAuth {
            let relogin = NSMenuItem(title: "Re-login…", action: #selector(reloginAccount(_:)), keyEquivalent: "")
            relogin.target = self; relogin.representedObject = account.id
            sub.addItem(relogin)
        }
        sub.addItem(.separator())
        let remove = NSMenuItem(title: "Remove", action: #selector(removeAccount(_:)), keyEquivalent: "")
        remove.target = self; remove.representedObject = account.id
        sub.addItem(remove)
    }

    /// Информационные пункты сабменю: без action (не кликаются), но с
    /// attributedTitle — иначе autoenablesItems глушит их в один серый и
    /// детали нечитаемы (фидбэк владельца 12.07: «неконтрастно»).
    private func addAccountDetails(_ sub: NSMenu, account: Account) {
        // Шапка ВСЕГДА начинается с identity аккаунта (фидбэк 12.07: «аккаунт
        // не во всех моделях виден» — после дедупа email==имя оставалось голое
        // «Claude Code»). Identity — контрастная, сервис · тариф — вторичным.
        let identity = AccountRowView.resolvedName(name: account.name, email: account.email)
        sub.addItem(infoItem(identity, color: .labelColor, semiboldPrefix: identity))
        let service = account.kind == .codex ? "Codex" : "Claude Code"
        sub.addItem(infoItem(account.plan.map { "\(service) · \($0)" } ?? service, color: .secondaryLabelColor))
        sub.addItem(.separator())

        switch poller.state(for: account.id) {
        case .pending:
            sub.addItem(infoItem("Loading…", color: .secondaryLabelColor))
            sub.addItem(.separator())
        case .failed(let badge):
            sub.addItem(infoItem(badge, color: .asbWarn))
            sub.addItem(.separator())
        case .ok(let usage, _), .stale(let usage, _, _):
            addWindowDetails(sub, title: "5-hour window", window: usage.fiveHour)
            addWindowDetails(sub, title: "Weekly window", window: usage.sevenDay)
            if case .stale(_, _, let badge) = poller.state(for: account.id) {
                sub.addItem(infoItem("⚠ \(badge)", color: .asbWarn))
            }
            sub.addItem(.separator())
        }
    }

    /// Одно окно = одна строка: «5-hour window — 51% · resets Mo 00:59 (in 1 hour)»
    /// (название semibold, хвост со сбросом — вторичным). Прогноз — отдельной
    /// оранжевой строкой сразу под своим окном.
    private func addWindowDetails(_ sub: NSMenu, title: String, window: UsageWindow?) {
        let detail = AccountRowView.windowDetail(title: title, window: window)
        let font = NSFont.menuFont(ofSize: 0)
        let line = NSMutableAttributedString(
            string: detail.summary,
            attributes: [.foregroundColor: NSColor.labelColor, .font: font])
        line.addAttribute(.font, value: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold),
                          range: NSRange(location: 0, length: title.utf16.count))
        if let reset = detail.reset {
            line.append(NSAttributedString(
                string: " · \(reset)",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: font]))
        }
        let item = NSMenuItem(title: detail.summary, action: nil, keyEquivalent: "")
        item.attributedTitle = line
        sub.addItem(item)
        if let forecast = detail.forecast {
            sub.addItem(infoItem(forecast, color: .asbWarn))
        }
    }

    private func infoItem(_ text: String, color: NSColor, semiboldPrefix: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        let font = NSFont.menuFont(ofSize: 0)
        let attributed = NSMutableAttributedString(
            string: text, attributes: [.foregroundColor: color, .font: font])
        if let prefix = semiboldPrefix, text.hasPrefix(prefix) {
            let bold = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
            attributed.addAttribute(.font, value: bold, range: NSRange(location: 0, length: prefix.utf16.count))
        }
        item.attributedTitle = attributed
        return item
    }

    private func render() {
        if menuIsOpen {
            refreshRowsInPlace()
        } else {
            rebuildMenu()
        }
        renderIcon()
        let f = DateFormatter(); f.timeStyle = .short
        updatedItem.title = "Updated \(f.string(from: Date()))"
    }

    /// Обновляет открытое меню без removeAllItems: та же геометрия, свежие данные.
    private func refreshRowsInPlace() {
        for item in menu.items {
            guard let id = item.representedObject as? UUID,
                  let account = store.accounts.first(where: { $0.id == id }),
                  let host = item.view as? NSHostingView<AccountRowView> else { continue }
            host.rootView = AccountRowView(name: account.name, state: poller.state(for: id),
                                           kind: account.kind, email: account.email, plan: account.plan)
        }
    }

    private func renderIcon() {
        let states = store.accounts.map { poller.state(for: $0.id) }
        statusItem.button?.image = IconRenderer.image(levels: IconRenderer.barLevels(states))
        statusItem.button?.toolTip = tooltip()
    }

    private func tooltip() -> String {
        let parts = store.accounts.compactMap { account -> String? in
            let pct: Int
            switch poller.state(for: account.id) {
            case .ok(let usage, _), .stale(let usage, _, _): pct = Int(usage.worstUtilization)
            case .failed, .pending: return nil   // skip accounts with no data
            }
            let label = (Account.defaultNames.contains(account.name) ? account.email : nil) ?? account.name
            return "\(label) \(pct)%"
        }
        return parts.joined(separator: " · ")
    }

    // MARK: actions
    @objc private func addAccount() { OAuthFlow.shared.start(store: store) { [weak self] in self?.render() } }
    @objc private func addCodexAccount() {
        // Codex-логин делает codex CLI (пишет auth.json в свой CODEX_HOME). Второй аккаунт =
        // отдельный CODEX_HOME. Даём выбрать его папку; read-only читаем оттуда auth.json.
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Choose a Codex home folder containing auth.json (e.g. ~/.codex, or a second CODEX_HOME you logged into with `codex login`)."
        panel.prompt = "Add"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let home = dir.path
        guard let auth = CodexAuth.load(homePath: home) else {
            let a = NSAlert()
            a.messageText = "No Codex login found there"
            a.informativeText = "That folder has no valid auth.json. Run `codex login` (optionally with CODEX_HOME set to this folder) first, then try again."
            a.runModal()
            return
        }
        // Дедуп: не добавлять тот же home, что уже есть (в т.ч. основной ~/.codex).
        let existingHomes = store.accounts.filter { $0.kind == .codex }
            .map { $0.codexHome ?? CodexAuth.defaultHomePath }
        if existingHomes.contains(home) { NSSound.beep(); return }
        let email = auth.email()
        store.add(Account(id: UUID(), name: email ?? "Codex", kind: .codex,
                          email: email, codexHome: home))
        render()
    }
    @objc private func addClaudeProfile() {
        // Второй Claude-аккаунт живёт в отдельном CLAUDE_CONFIG_DIR; логинит его сам
        // Claude Code (кладёт креды в Keychain-сервис с hash-суффиксом от пути папки).
        // Даём выбрать папку профиля; read-only читаем токены из Keychain.
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Choose a Claude config folder (e.g. ~/.claude-max2 — a CLAUDE_CONFIG_DIR you logged into with `claude /login`)."
        panel.prompt = "Add"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let configDir = dir.path
        guard KeychainStore.claudeCodeTokens(configDir: configDir) != nil else {
            let a = NSAlert()
            a.messageText = "No Claude login found for that profile"
            a.informativeText = "No Keychain credentials exist for this folder. Run `CLAUDE_CONFIG_DIR=<folder> claude` and `/login` first, then try again."
            a.runModal()
            return
        }
        // Дедуп по конфиг-папке (nil = основной автоподхваченный ~/.claude).
        let existingDirs = store.accounts.filter { $0.kind == .claudeMain }.map { $0.claudeConfigDir }
        if existingDirs.contains(configDir) { NSSound.beep(); return }
        store.add(Account(id: UUID(), name: "Claude 2", kind: .claudeMain, email: nil,
                          claudeConfigDir: configDir))
        render()
    }
    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do { svc.status == .enabled ? try svc.unregister() : try svc.register() }
        catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        rebuildMenu()
    }
    private static let usageAlertsKey = "usageAlertsEnabled"
    @objc private func toggleUsageAlerts() {
        let defaults = UserDefaults.standard
        let newValue = !defaults.bool(forKey: Self.usageAlertsKey)
        defaults.set(newValue, forKey: Self.usageAlertsKey)
        if newValue { Notifier.requestAuthorization() }
        rebuildMenu()
    }
    @objc private func checkUpdates() { Updates.check(announce: true) }
    @objc private func openRepo() {
        NSWorkspace.shared.open(URL(string: "https://github.com/sshykvlv/ai-status-bar")!)
    }
    @objc private func renameAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let account = store.accounts.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Account"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = account.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
            store.rename(id: id, to: field.stringValue)
            render()
        }
    }
    @objc private func reloginAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        OAuthFlow.shared.start(store: store, reloginID: id) { [weak self] in self?.render() }
    }
    @objc private func removeAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        store.remove(id: id)
        render()
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
