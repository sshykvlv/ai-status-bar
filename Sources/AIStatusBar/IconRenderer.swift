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
                if u.worstUtilization >= 90 { severity = .danger }
                else if u.worstUtilization >= 70 { severity = .warn }
                else { severity = .normal }
                return BarLevel(used: used, severity: severity)
            case .failed, .pending:
                return BarLevel(used: nil, severity: .normal)
            }
        }
    }

    static let barWidth: CGFloat = 3
    static let segmentCount = 5
    static let segmentHeight: CGFloat = 2
    static let segmentGap: CGFloat = 1
    static let barHeight = CGFloat(segmentCount) * segmentHeight
        + CGFloat(segmentCount - 1) * segmentGap

    /// Высота стека завершённых 20%-сегментов. Точный процент остаётся в tooltip;
    /// значок отвечает на более быстрый вопрос: сколько полных пятых уже потрачено.
    static func fillHeight(used: Double) -> CGFloat {
        guard used.isFinite else { return 0 }
        let clamped = min(max(used, 0), 1)
        let filled = min(Int((clamped * Double(segmentCount)).rounded(.down)), segmentCount)
        guard filled > 0 else { return 0 }
        return CGFloat(filled) * segmentHeight + CGFloat(filled - 1) * segmentGap
    }

    static func image(levels rawLevels: [BarLevel]) -> NSImage {
        // Столбик на аккаунт: пять дискретных сегментов снизу вверх, каждый = полные
        // 20% расхода. Цвет — нейтральный/оранжевый/красный по точному уровню.
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
                let filledHeight = level.used.map(fillHeight) ?? 0
                for segment in 0..<segmentCount {
                    let segmentY = y + CGFloat(segment) * (segmentHeight + segmentGap)
                    let rect = NSRect(x: x, y: segmentY, width: barW, height: segmentHeight)
                    NSColor.labelColor.withAlphaComponent(0.35).setFill()
                    NSBezierPath(rect: rect).fill()

                    let segmentTop = CGFloat(segment + 1) * segmentHeight
                        + CGFloat(segment) * segmentGap
                    if filledHeight >= segmentTop {
                        fillColor(for: level.severity).setFill()
                        NSBezierPath(rect: rect).fill()
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
