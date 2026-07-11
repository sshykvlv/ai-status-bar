import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var store: AccountStore!
    private var poller: Poller!
    private let menu = NSMenu()
    private let updatedItem = NSMenuItem(title: "Updated —", action: nil, keyEquivalent: "")

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
        rebuildMenu()
        renderIcon()
        poller.start()
        Updates.check(announce: false)
    }

    func menuWillOpen(_ menu: NSMenu) { poller.pollNow() }

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
        menu.addItem(.separator())
        let login = addAction("Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        addAction("Check for Updates…", #selector(checkUpdates))
        addAction("View on GitHub", #selector(openRepo))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit LimitBar",
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
            sub.addItem(.separator())
            let remove = NSMenuItem(title: "Remove", action: #selector(removeAccount(_:)), keyEquivalent: "")
            remove.target = self; remove.representedObject = account.id
            sub.addItem(remove)
        }
        return sub
    }

    private func render() {
        rebuildMenu()
        renderIcon()
        let f = DateFormatter(); f.timeStyle = .short
        updatedItem.title = "Updated \(f.string(from: Date()))"
    }

    private func renderIcon() {
        let states = store.accounts.map { poller.state(for: $0.id) }
        // NOTE: IconRenderer draws hot (non-template) bars in solid black/red,
        // which is invisible against a dark menu bar. Calm icons stay template
        // (auto-tinted by the system) and cover the common case; the hot-mode
        // dark-appearance contrast issue is a known v1 limitation — tracked for
        // a follow-up rather than fixed here (see Task 9 self-review).
        statusItem.button?.image = IconRenderer.image(levels: IconRenderer.barLevels(states))
    }

    // MARK: actions
    @objc private func addAccount() { OAuthFlow.shared.start(store: store) { [weak self] in self?.render() } }
    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do { svc.status == .enabled ? try svc.unregister() : try svc.register() }
        catch { NSSound.beep() }
        rebuildMenu()
    }
    @objc private func checkUpdates() { Updates.check(announce: true) }
    @objc private func openRepo() {
        NSWorkspace.shared.open(URL(string: "https://github.com/sshykvlv/limitbar")!)
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
