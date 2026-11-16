import AppKit
import SwiftUI

// Блок «Mac» в меню: сводка-вердикт + 3 главных потребителя. Вид согласован
// владельцем 16.11 (живой спайк + минималистичный проход Fable), см.
// docs/superpowers/specs/2026-11-16-mac-stats-design.md.

/// Сводка: «Mac» + один чип-вердикт. Цвет только у тревоги — залитая плашка
/// (asbWarnFill/asbDangerFill, белый текст ≥4.5:1), в покое — серый чип.
struct MacSummaryRow: View {
    let verdict: Verdict?
    @State private var hovered = false

    private var alertFill: Color? {
        switch verdict?.level {
        case .warn: return Color(nsColor: .asbWarnFill)
        case .critical: return Color(nsColor: .asbDangerFill)
        default: return nil
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("Mac").font(.system(size: 12.5, weight: .medium))
                .foregroundColor(hovered ? .white : .primary)
            Spacer(minLength: 12)
            Text(verdict?.text ?? "—")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(hovered || alertFill != nil ? .white : Color(nsColor: .secondaryLabelColor))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, SystemRowMetrics.chipInset)
                // Асимметрия — тот же квирк лидинга NSMenu, что у WindowChip.
                .padding(.top, 3)
                .padding(.bottom, 2)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(alertFill ?? (hovered ? Color.white.opacity(0.18)
                                        : Color(nsColor: .quaternarySystemFill))))
            SystemChevron(hovered: hovered)
        }
        .systemRow(hovered: $hovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Mac, \(verdict?.text ?? "loading")"))
    }
}

/// Потребитель простым текстом, без цвета: ранг задан порядком строк, тревогу
/// несёт один чип сводки. Справа — память, а при вердикте «CPU» — проценты.
struct ConsumerRow: View {
    let consumer: Consumer
    let byCPU: Bool
    @State private var hovered = false

    static func metric(_ c: Consumer, byCPU: Bool) -> String {
        byCPU ? "\(Int(c.cpuPercent.rounded()))%" : ByteText.gb(c.footprint)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            (Text(consumer.title)
                .font(.system(size: 12.5))
                .foregroundColor(hovered ? .white : .primary)
             + Text(consumer.rootPids.count > 1 ? " ×\(consumer.rootPids.count)" : "")
                .font(.system(size: 11))
                .foregroundColor(hovered ? .white.opacity(0.85) : Color(nsColor: .secondaryLabelColor)))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            Text(Self.metric(consumer, byCPU: byCPU))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(hovered ? .white : .primary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                // Правый край цифр — в столбец с текстом чипа сводки.
                .padding(.trailing, SystemRowMetrics.chipInset)
            SystemChevron(hovered: hovered)
        }
        .systemRow(hovered: $hovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(consumer.title), \(Self.metric(consumer, byCPU: byCPU))"))
    }
}

private enum SystemRowMetrics {
    static let chipInset: CGFloat = 7
}

private struct SystemChevron: View {
    let hovered: Bool
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(hovered ? Color.white : Color(nsColor: .labelColor))
            .padding(.leading, 2)
    }
}

private extension View {
    /// Геометрия и подсветка строки — как у AccountRowView.
    func systemRow(hovered: Binding<Bool>) -> some View {
        self.padding(.horizontal, 12)
            .frame(minWidth: MenuRowFactory.rowWidth, maxWidth: .infinity,
                   minHeight: MenuRowFactory.rowHeight, maxHeight: MenuRowFactory.rowHeight,
                   alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .selectedContentBackgroundColor))
                .opacity(hovered.wrappedValue ? 1 : 0)
                .padding(.horizontal, 5))
            .onHover { hovered.wrappedValue = $0 }
    }
}

/// Владеет опросом и строками блока. Опрос — фоновая очередь каждые 10 с,
/// каждые 2 с пока меню открыто. Пока меню открыто, набор и порядок строк
/// заморожены (обновляются только цифры): строки не прыгают под курсором, а
/// сабменю не мутируются при показе (квирк высоты окна, см. main.swift).
@MainActor
final class SystemMenuController: NSObject {
    static let enabledKey = "macStatsEnabled"
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private let sampler = SystemSampler()
    private let queue = DispatchQueue(label: "AIStatusBar.SystemSampler", qos: .utility)
    private var timer: Timer?
    private var sampling = false
    private(set) var snapshot: SystemSnapshot?
    private var procs: [ProcSample] = []
    private let mock: Bool

    private var summaryItem: NSMenuItem?
    private var consumerItems: [NSMenuItem] = []
    /// Ключи строк, показанных при открытии меню (заморозка порядка).
    private var frozenKeys: [String]?

    init(mock: Bool = MockData.enabled) {
        self.mock = mock
        super.init()
        if mock { snapshot = MockData.systemSnapshot }
    }

    func start() {
        guard !mock else { return }
        sampleNow()
        schedule(interval: 10)
    }

    func stop() {
        timer?.invalidate(); timer = nil
    }

    func menuWillOpen() {
        // Содержимое и сабменю — до показа окна (как у сабменю аккаунтов в
        // main.swift); дальше, пока открыто, меняются только цифры.
        frozenKeys = nil
        populate()
        frozenKeys = currentTop().map(\.key)
        guard !mock else { return }
        sampleNow()
        schedule(interval: 2)
    }

    func menuDidClose() {
        frozenKeys = nil
        guard !mock, timer != nil else { return }
        schedule(interval: 10)
    }

    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleNow() }
        }
    }

    private func sampleNow() {
        guard !sampling else { return }
        sampling = true
        let sampler = self.sampler
        queue.async {
            let snap = sampler.sample()
            let procs = sampler.lastProcs
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sampling = false
                self.snapshot = snap
                self.procs = procs
                self.refreshInPlace()
            }
        }
    }

    private var verdict: Verdict? { snapshot.map(Verdict.init) }

    private func currentTop() -> [Consumer] {
        guard let snapshot, let verdict else { return [] }
        return SystemModel.top(snapshot, verdict: verdict)
    }


    // MARK: menu items

    /// Полный набор пунктов блока: сводка + ровно 3 строки (лишние скрыты),
    /// чтобы обновление на месте никогда не меняло высоту открытого меню.
    func items() -> [NSMenuItem] {
        let summary = NSMenuItem()
        summary.view = Self.host(MacSummaryRow(verdict: verdict))
        summaryItem = summary
        consumerItems = (0..<SystemModel.visibleConsumers).map { _ in
            let item = NSMenuItem()
            item.view = Self.host(ConsumerRow(consumer: Self.placeholder, byCPU: false))
            return item
        }
        populate()
        return [summary] + consumerItems
    }

    private static let placeholder = Consumer(key: "", title: "", kind: .process, rootPids: [],
                                              allPids: [], footprint: 0, cpuPercent: 0, helpers: 0)

    /// Полное заполнение: строки, видимость и сабменю. Только пока меню закрыто
    /// или в menuWillOpen — до показа окна.
    private func populate() {
        guard let summaryItem else { return }
        updateSummary()
        summaryItem.submenu = summarySubmenu()
        let top = currentTop()
        let byCPU = verdict?.byCPU ?? false
        for (i, item) in consumerItems.enumerated() {
            guard i < top.count else { item.isHidden = true; item.submenu = nil; continue }
            item.isHidden = false
            (item.view as? NSHostingView<ConsumerRow>)?.rootView = ConsumerRow(consumer: top[i], byCPU: byCPU)
            item.title = top[i].title
            item.submenu = consumerSubmenu(top[i])
        }
    }

    private func updateSummary() {
        (summaryItem?.view as? NSHostingView<MacSummaryRow>)?.rootView = MacSummaryRow(verdict: verdict)
        summaryItem?.title = "Mac — \(verdict?.text ?? "loading")"
    }

    /// Новый замер. Меню закрыто — полное заполнение; открыто — только цифры
    /// тех же строк в том же порядке (строки не прыгают под курсором, режим
    /// сортировки и сабменю не меняются).
    func refreshInPlace() {
        guard let keys = frozenKeys else { populate(); return }
        updateSummary()
        guard let snapshot else { return }
        let pool = currentTop() + snapshot.consumers
        for (i, item) in consumerItems.enumerated() where i < keys.count {
            guard let fresh = pool.first(where: { $0.key == keys[i] }),
                  let host = item.view as? NSHostingView<ConsumerRow> else { continue }
            host.rootView = ConsumerRow(consumer: fresh, byCPU: host.rootView.byCPU)
        }
    }

    private static func host<V: View>(_ view: V) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []   // см. «gap after Quit» в MenuRowFactory
        host.frame = NSRect(x: 0, y: 0, width: MenuRowFactory.rowWidth, height: MenuRowFactory.rowHeight)
        host.autoresizingMask = [.width]
        return host
    }

    private func info(_ text: String, _ color: NSColor = .secondaryLabelColor, bold: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        let font = NSFont.menuFont(ofSize: 0)
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: bold ? NSFont.systemFont(ofSize: font.pointSize, weight: .semibold) : font])
        return item
    }

    private func action(_ title: String, _ sel: Selector, _ object: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        return item
    }

    private func summarySubmenu() -> NSMenu {
        let sub = NSMenu()
        guard let s = snapshot else {
            sub.addItem(info("Loading…"))
            return sub
        }
        switch s.pressure {
        case .critical: sub.addItem(info("Memory pressure is critical", .asbDanger, bold: true))
        case .warn: sub.addItem(info("Memory pressure is high", .asbWarn, bold: true))
        case .normal: break
        }
        sub.addItem(info("Memory  \(ByteText.gb(s.memUsed)) of \(ByteText.gb(s.memTotal))"))
        sub.addItem(info("Swap  \(ByteText.gb(s.swapUsed))"))
        sub.addItem(info("CPU  \(Int(s.cpuPercent.rounded()))%"))
        let topKeys = Set(currentTop().map(\.key))
        if !s.leftovers.isEmpty, !topKeys.contains("leftovers") {
            sub.addItem(.separator())
            let total = s.leftovers.reduce(0) { $0 + $1.footprint }
            let left = NSMenuItem(title: "Leftovers ×\(s.leftovers.count) · \(ByteText.gb(total))",
                                  action: nil, keyEquivalent: "")
            left.submenu = leftoversSubmenu(s.leftovers)
            sub.addItem(left)
        }
        sub.addItem(.separator())
        sub.addItem(action("Open Activity Monitor", #selector(openActivityMonitor)))
        return sub
    }

    private func consumerSubmenu(_ c: Consumer) -> NSMenu {
        if c.kind == .leftovers, let s = snapshot { return leftoversSubmenu(s.leftovers) }
        let sub = NSMenu()
        let n = c.rootPids.count
        var parts: [String] = []
        if n > 1 { parts.append("\(n) processes") }
        if c.helpers > 0 { parts.append("\(c.helpers) helpers") }
        parts.append(ByteText.gb(c.footprint))
        sub.addItem(info(parts.joined(separator: " · ")))
        sub.addItem(.separator())
        sub.addItem(action(n > 1 ? "Quit All \(n)" : "Quit", #selector(quitConsumer(_:)), c.key))
        sub.addItem(action(n > 1 ? "Force Quit All \(n)" : "Force Quit", #selector(forceQuitConsumer(_:)), c.key))
        return sub
    }

    private func leftoversSubmenu(_ leftovers: [Leftover]) -> NSMenu {
        let sub = NSMenu()
        sub.addItem(info("Agent helpers whose session has exited"))
        sub.addItem(info("Some may be servers started on purpose"))
        sub.addItem(.separator())
        for l in leftovers {
            let title = "\(l.label) — \(l.tool) · \(Self.age(l.age)) · \(ByteText.gb(l.footprint))"
            sub.addItem(action(title, #selector(quitLeftover(_:)), l.pid))
        }
        if leftovers.count > 1 {
            sub.addItem(.separator())
            sub.addItem(action("Quit All Leftovers", #selector(quitAllLeftovers)))
        }
        return sub
    }

    static func age(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        if m < 60 { return "\(max(m, 1)) min" }
        if m < 24 * 60 { return "\(m / 60) h" }
        return "\(m / (24 * 60)) d"
    }

    // MARK: actions

    /// Свежие процессы, совпадающие со снимком по pid + времени старта.
    private func liveProcs() -> [ProcSample] {
        ProcessKiller.stillSame(old: procs, fresh: SystemSampler.readProcs())
    }

    private func consumer(for sender: NSMenuItem) -> Consumer? {
        guard let key = sender.representedObject as? String, let s = snapshot else { return nil }
        if key == "leftovers" { return currentTop().first { $0.key == key } }
        return s.consumers.first { $0.key == key }
    }

    private func confirm(_ title: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = "Their running work stops. Unsaved changes may be lost."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func confirmTitle(_ c: Consumer, force: Bool) -> String? {
        let n = c.rootPids.count
        if force { return n > 1 ? "Force quit \(n) \(c.title) processes?" : "Force quit \(c.title)?" }
        guard c.kind == .agent else { return nil }
        return n > 1 ? "Quit \(n) \(c.title) sessions?" : "Quit \(c.title)?"
    }

    @objc private func quitConsumer(_ sender: NSMenuItem) {
        guard let c = consumer(for: sender) else { return }
        if let title = Self.confirmTitle(c, force: false), !confirm(title) { return }
        guard !mock else { return }
        ProcessKiller.quit(c, procs: liveProcs())
        sampleSoon()
    }

    @objc private func forceQuitConsumer(_ sender: NSMenuItem) {
        guard let c = consumer(for: sender),
              let title = Self.confirmTitle(c, force: true), confirm(title) else { return }
        guard !mock else { return }
        ProcessKiller.forceQuit(c, procs: liveProcs())
        sampleSoon()
    }

    @objc private func quitLeftover(_ sender: NSMenuItem) {
        guard let pid = sender.representedObject as? Int32,
              let l = snapshot?.leftovers.first(where: { $0.pid == pid }), !mock else { return }
        ProcessKiller.quit(l, procs: liveProcs())
        sampleSoon()
    }

    @objc private func quitAllLeftovers() {
        guard let leftovers = snapshot?.leftovers, !mock else { return }
        let live = liveProcs()
        leftovers.forEach { ProcessKiller.quit($0, procs: live) }
        sampleSoon()
    }

    @objc private func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    /// После сигнала процессам нужна секунда, чтобы выйти.
    private func sampleSoon() {
        guard !mock else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.sampleNow() }
    }
}
