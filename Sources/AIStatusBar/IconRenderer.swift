import AppKit

enum IconRenderer {
    enum Severity: Equatable {
        case normal, warn, danger
    }

    struct BarLevel: Equatable {
        let used: Double?        // 0…1, доля израсходованного; nil = нет данных
        let severity: Severity
    }

    /// Один бар на аккаунт. Заполнение = израсходовано (worstUtilization), цвет по нему же:
    /// >90% → danger (красный), >70% → warn (жёлтый), иначе normal (зелёный).
    static func barLevels(_ states: [AccountState]) -> [BarLevel] {
        states.map { state in
            switch state {
            case .ok(let u, _), .stale(let u, _, _):
                let used = min(max(u.worstUtilization / 100, 0), 1)
                let severity: Severity
                if u.worstUtilization > 90 { severity = .danger }
                else if u.worstUtilization > 70 { severity = .warn }
                else { severity = .normal }
                return BarLevel(used: used, severity: severity)
            case .failed, .pending:
                return BarLevel(used: nil, severity: .normal)
            }
        }
    }

    static let barWidth: CGFloat = 3
    static let barHeight: CGFloat = 15

    /// Высота заливки бара для доли израсходованного (0…1). Пропорциональна used,
    /// с маленьким полом (1pt) только чтобы почти нулевой ненулевой расход не был
    /// невидимым — не 20% высоты бара, как было раньше (см. историю в image()).
    static func fillHeight(used: Double) -> CGFloat {
        guard used > 0 else { return 0 }
        return max(1, barHeight * used)
    }

    static func image(levels rawLevels: [BarLevel]) -> NSImage {
        // Столбик на аккаунт, высота = сколько израсходовано у этой модели (снизу вверх),
        // цвет — зелёный/жёлтый/красный по уровню. Никаких цифр: столбики сами показывают
        // реальный статус каждой модели.
        // levels.isEmpty (нет ни одного настроенного аккаунта, не просто "данные ещё не
        // пришли") раньше рендерило буквально пустой канвас — ни одного трека не рисовалось,
        // потому что цикл ниже идёт по levels. Значок в менюбаре становился невидимым (owner
        // repro: удалил все аккаунты во время миграции на .claudeOAuth → иконка пропала,
        // нечем было кликнуть "Add Account…"). Подставляем один пустой трек-плейсхолдер,
        // как для .pending — та же визуальная лексика "данных нет", но остаётся видимым и
        // кликабельным.
        let levels = rawLevels.isEmpty ? [BarLevel(used: nil, severity: .normal)] : rawLevels
        let barW = barWidth, gap: CGFloat = 2, barH = barHeight, canvasH: CGFloat = 18
        let count = max(levels.count, 1)
        let width = CGFloat(count) * barW + CGFloat(count - 1) * gap + 2
        // Template оставляем только когда данных нет вовсе (пустой значок).
        let hasData = levels.contains { $0.used != nil }
        let img = NSImage(size: NSSize(width: width, height: canvasH), flipped: false) { _ in
            let y = (canvasH - barH) / 2
            for (i, level) in levels.enumerated() {
                let x = 1 + CGFloat(i) * (barW + gap)
                let track = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barW, height: barH),
                                         xRadius: barW / 2, yRadius: barW / 2)
                // Подложка от labelColor — адаптируется к светлому/тёмному менюбару
                // (drawingHandler выполняется в appearance кнопки статус-айтема).
                NSColor.labelColor.withAlphaComponent(0.35).setFill()
                track.fill()
                if let used = level.used {
                    let h = fillHeight(used: used)
                    if h > 0 {
                        let fill = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barW, height: h),
                                                xRadius: barW / 2, yRadius: barW / 2)
                        fillColor(for: level.severity).setFill()
                        fill.fill()
                    }
                }
            }
            return true
        }
        img.isTemplate = !hasData
        return img
    }

    // Спокойный бар — нейтральный (фидбэк владельца 12.07: красим только когда
    // токенов мало) — labelColor, а не белый: адаптируется к светлому менюбару.
    // Warn — оранжевый, как пороговые цвета в строках меню (был жёлтый).
    private static func fillColor(for severity: Severity) -> NSColor {
        switch severity {
        case .danger: return .systemRed
        case .warn: return .asbWarn
        case .normal: return .labelColor
        }
    }
}
