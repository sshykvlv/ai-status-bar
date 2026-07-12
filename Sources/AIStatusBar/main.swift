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
        menuIsOpen = true
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
        let sub = NSMenu()
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
        return sub
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

    /// Names an owner never customized, used as a fallback signal that a row's
    /// email (once fetched) is more informative than its generic default name.
    private static let defaultAccountNames: Set<String> = ["Claude", "Codex", "Claude 2"]

    private func tooltip() -> String {
        let parts = store.accounts.compactMap { account -> String? in
            let pct: Int
            switch poller.state(for: account.id) {
            case .ok(let usage, _), .stale(let usage, _, _): pct = Int(usage.worstUtilization)
            case .failed, .pending: return nil   // skip accounts with no data
            }
            let label = (Self.defaultAccountNames.contains(account.name) ? account.email : nil) ?? account.name
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
    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do { svc.status == .enabled ? try svc.unregister() : try svc.register() }
        catch { NSSound.beep() }
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
