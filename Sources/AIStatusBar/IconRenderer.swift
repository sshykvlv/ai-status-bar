import AppKit

enum IconRenderer {
    enum Severity: Equatable {
        case normal, notice, warn, danger
    }

    struct BarLevel: Equatable {
        let used: Double?        // 0…1, доля израсходованного; nil = нет данных
        let severity: Severity
    }

    /// Один бар на аккаунт. Высота точно показывает worstUtilization, а цвет всего
    /// заполнения меняется на каждой четверти: зелёный, жёлтый, оранжевый, красный.
    static func barLevels(_ states: [AccountState]) -> [BarLevel] {
        states.map { state in
            switch state {
            case .ok(let u, _), .stale(let u, _, _):
                let used = min(max(u.worstUtilization / 100, 0), 1)
                let severity: Severity
                if u.worstUtilization >= 75 { severity = .danger }
                else if u.worstUtilization >= 50 { severity = .warn }
                else if u.worstUtilization >= 25 { severity = .notice }
                else { severity = .normal }
                return BarLevel(used: used, severity: severity)
            case .failed, .pending:
                return BarLevel(used: nil, severity: .normal)
            }
        }
    }

    static let barWidth: CGFloat = 3
    static let barHeight: CGFloat = 15

    /// Непрерывная высота заливки для точного процента. 1pt-пол оставляет видимым
    /// ненулевой расход, а значения вне диапазона безопасно зажимаются в 0…100%.
    static func fillHeight(used: Double) -> CGFloat {
        guard used.isFinite, used > 0 else { return 0 }
        let clamped = min(max(used, 0), 1)
        return max(1, barHeight * clamped)
    }

    static func image(levels rawLevels: [BarLevel]) -> NSImage {
        // Столбик на аккаунт: одна непрерывная полоса с точной высотой расхода.
        // Цвет всей заливки переключается на порогах 25%, 50% и 75%.
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
                NSColor.labelColor.withAlphaComponent(0.35).setFill()
                track.fill()
                if let used = level.used {
                    let height = fillHeight(used: used)
                    if height > 0 {
                        let fill = NSBezierPath(
                            roundedRect: NSRect(x: x, y: y, width: barW, height: height),
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

    private static func fillColor(for severity: Severity) -> NSColor {
        switch severity {
        case .danger: return .systemRed
        case .warn: return .systemOrange
        case .notice: return .systemYellow
        case .normal: return .systemGreen
        }
    }
}
