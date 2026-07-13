import SwiftUI
import AppKit

struct AccountRowView: View {
    let name: String
    let state: AccountState
    let kind: AccountKind
    var email: String? = nil
    var plan: String? = nil

    @State private var hovered = false

    // Одна строка: identity = email вместо generic-имени (та же fallback-логика,
    // что в тултипе менюбара), суффикс сервиса — один email может быть и на
    // Claude, и на Codex. Кольца убраны (на 16pt дуга не читается). Правая часть —
    // «D2, только цифры», см. комментарий у windows(usage:). Полные слова
    // («resets», тариф) — только в тултипах.
    private var serviceSuffix: String {
        switch kind {
        case .claudeMain, .claudeOAuth: return "Claude"
        case .codex: return "Codex"
        }
    }

    private var serviceLabel: String {
        switch kind {
        case .claudeMain, .claudeOAuth: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// Дефолтное имя ничего не говорит — показываем email, когда он есть.
    /// Общая точка для строки меню и шапки сабменю деталей.
    static func resolvedName(name: String, email: String?) -> String {
        Account.defaultNames.contains(name) ? (email ?? name) : name
    }

    private var resolvedName: String { Self.resolvedName(name: name, email: email) }

    // «Claude · Claude» у дефолтного имени без email — дубль: суффикс различает
    // сервисы при одинаковых identity, а тут identity и есть имя сервиса.
    private var showsSuffix: Bool { resolvedName != serviceSuffix }

    /// Детализация одного окна для сабменю аккаунта (выбор владельца 12.07:
    /// детали выпадают вправо сабменю; одна строка на окно, без пересчётов
    /// вроде «49% left» — фидбэк «избавимся от лишнего»).
    static func windowDetail(title: String, window: UsageWindow?)
        -> (summary: String, reset: String?, forecast: String?) {
        guard let window else { return ("\(title) — no data", nil, nil) }
        let summary = "\(title) — \(Int(window.utilization))%"
        var reset: String? = nil
        if let resetsAt = window.resetsAt, let absolute = ResetClock.label(resetsAt) {
            let rel = RelativeDateTimeFormatter(); rel.unitsStyle = .full
            reset = "resets \(absolute) (\(rel.localizedString(for: resetsAt, relativeTo: .now)))"
        }
        var forecast: String? = nil
        if let projected = window.projectedExhaustion, let label = ResetClock.label(projected) {
            forecast = "At this pace, hits 100% ~\(label)"
        }
        return (summary, reset, forecast)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            (Text(resolvedName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(hovered ? Color.white : Color.primary)
             + Text(showsSuffix ? " · \(serviceSuffix)" : "")
                .font(.system(size: 11))
                .foregroundColor(hovered ? Color.white.opacity(0.85) : Color(nsColor: .secondaryLabelColor)))
                .lineLimit(1)
                .truncationMode(.middle)
            if case .stale = state {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
            // Identity гибкая, сегменты окон прижаты вправо: фиксированная ширина
            // выравнивает проценты и времена в столбцы между строками.
            Spacer(minLength: 12)
            switch state {
            case .pending:
                windows(usage: nil)
            case .failed(let badge):
                Label(badge, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            case .ok(let usage, _), .stale(let usage, _, _):
                windows(usage: usage)
            }
            // Системную стрелку сабменю view-item не рисует — своя (просьба
            // владельца 12.07: у пунктов с выпадайкой должна быть стрелка).
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hovered ? Color.white : Color(nsColor: .tertiaryLabelColor))
                .padding(.leading, 2)
        }
        .padding(.horizontal, 12)
        .frame(width: MenuRowFactory.rowWidth, height: MenuRowFactory.rowHeight, alignment: .leading)
        // Нативная подсветка выделения: кастомные view-строки NSMenu сам не
        // подсвечивает — рисуем акцентный rounded-rect с инсетом 5pt, как у
        // системных пунктов; цвет — системный selection (следует за акцентом юзера).
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .selectedContentBackgroundColor))
                .opacity(hovered ? 1 : 0)
                .padding(.horizontal, 5)
        )
        .onHover { hovered = $0 }
    }

    // Дизайн «F2 — раздельные плашки» (выбор владельца 12.07, эволюция «D2 — только
    // цифры»): каждое окно в своей плашке-чипе (слева всегда 5h, справа 7d), по
    // паттерну капсул Control Center, но со скруглённым прямоугольником — «не
    // колбаской». Внутри чипа только процент: серый пока спокойно (<70), оранжевый
    // ≥70, красный ≥90. Исключения ровно два: исчерпанное окно дописывает время
    // возврата (главный вопрос в этот момент), оранжевая молния = burn-rate прогноз
    // своего окна (цифры выглядят спокойно, а окно кончится до сброса). Красной
    // молнии нет — исчерпание видно по 100%. Метки окон, слова и детали — в тултипе.
    @ViewBuilder
    private func windows(usage: Usage?) -> some View {
        HStack(spacing: 6) {
            WindowChip(window: usage?.fiveHour, hovered: hovered)
            WindowChip(window: usage?.sevenDay, hovered: hovered)
        }
        // Кластер окон не сжимается — при длинной identity усекается она, не цифры.
        .layoutPriority(1)
    }

}

/// Абсолютное время сброса окна: сегодня — «19:00», иначе — «Tu 09:00»
/// (двухбуквенный день, локале-зависимые форматы). Владелец 11.07: конкретное
/// время полезнее, чем «через сколько часов», — показываем его всегда.
enum ResetClock {
    static func label(_ date: Date?, now: Date = .now, calendar: Calendar = .current) -> String? {
        guard let date else { return nil }
        if date <= now { return "now" }
        let f = DateFormatter()
        f.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            f.setLocalizedDateFormatFromTemplate("jm")
        } else {
            f.setLocalizedDateFormatFromTemplate("EEEEEE jm")
        }
        return f.string(from: date)
    }
}

/// Плашка-чип одного окна: процент, окрашенный порогом — серый пока спокойно
/// (<70), оранжевый ≥70, красный ≥90 (semibold + tabular). Исчерпанное окно
/// (>99%) — единственное, кому цифры мало: дописывает время возврата
/// «100% · 13:44». Молния слева — burn-rate прогноз этого окна.
/// `window == nil` — «—». Форма — скруглённый прямоугольник (не капсула),
/// заливка quaternary — как системные чипы.
private struct WindowChip: View {
    let window: UsageWindow?
    var hovered: Bool = false

    // Семантически правильный фон чипа — fill-роль, не label-роль: label-цвета
    // по HIG предназначены для текста. systemFill появился в macOS 14;
    // на 13 остаёмся на quaternaryLabel (визуально эквивалентен).
    static var chipFill: Color {
        if #available(macOS 14.0, *) {
            return Color(nsColor: .quaternarySystemFill)
        }
        return Color(nsColor: .quaternaryLabelColor)
    }

    private var exhausted: Bool { (window?.utilization ?? 0) > 99 }

    private var forecast: Bool {
        guard let window else { return false }
        return window.utilization <= 99 && window.projectedExhaustion != nil
    }

    private var percentColor: Color {
        if hovered { return .white }
        guard let util = window?.utilization else { return Color(nsColor: .tertiaryLabelColor) }
        if util >= 90 { return Color(nsColor: .systemRed) }
        if util >= 70 { return Color(nsColor: .asbWarn) }
        return Color(nsColor: .secondaryLabelColor)
    }

    private var resetSuffix: String {
        guard exhausted, let time = ResetClock.label(window?.resetsAt) else { return "" }
        return " · \(time)"
    }

    var body: some View {
        HStack(spacing: 4) {
            if forecast {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(hovered ? Color.white : Color(nsColor: .asbWarn))
            }
            (Text(window.map { "\(Int($0.utilization))%" } ?? "—")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(percentColor)
             + Text(resetSuffix)
                .font(.system(size: 11))
                // На выделенной (синей) строке серые тексты теряют контраст — в белый.
                .foregroundColor(hovered ? .white.opacity(0.85) : Color(nsColor: .secondaryLabelColor)))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 7)
        // В живом NSMenu текстовый бокс резолвится с лишним лидингом снизу —
        // при симметричном паддинге цифры прижимаются к верху чипа (замер:
        // ~9px сверху против ~14px снизу @2x). Асимметрия центрирует глифы;
        // офскрин-рендер (RowRenderTests) этого квирка не воспроизводит.
        .padding(.top, 3)
        .padding(.bottom, 2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovered ? Color.white.opacity(0.18) : Self.chipFill)
        )
    }
}

enum MenuRowFactory {
    static let rowWidth: CGFloat = 400
    // Одна текстовая строка 12.5pt + по ~5pt воздуха сверху/снизу (V2-B,
    // выбор владельца 12.07 — ниже и плотнее двухстрочного варианта).
    static let rowHeight: CGFloat = 25

    static func item(for account: Account, state: AccountState) -> NSMenuItem {
        let item = NSMenuItem()
        let row = AccountRowView(name: account.name, state: state, kind: account.kind,
                                  email: account.email, plan: account.plan)
        let host = NSHostingView(rootView: row)
        // Disable NSHostingView's own intrinsic-size layout so it can't leave stale sizing
        // slack in the parent NSMenu window (the "gap after Quit" gotcha). macOS 13+.
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: rowWidth, height: rowHeight)
        item.view = host
        // Title у view-item не рисуется (NSMenuItem.view забирает отрисовку),
        // но продолжает питать type-select и VoiceOver — заполняем всегда.
        item.title = account.name
        item.representedObject = account.id
        return item
    }
}
